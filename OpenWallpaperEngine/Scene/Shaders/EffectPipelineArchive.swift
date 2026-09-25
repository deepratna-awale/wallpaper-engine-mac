import Foundation
import Metal

/// An `MTLBinaryArchive` of effect pipeline states, kept in the cache directory so a later launch
/// skips the GPU backend compile of every pipeline it has seen.
///
/// One file per GPU (name and registry ID), OS build and app build: a binary compiled for one of
/// those is useless, or unsafe to hand the driver, under another. Files for the same GPU with an
/// older key are deleted. A file Metal refuses to open is deleted and replaced by an empty
/// archive. Writes go to a temporary file that is renamed into place, so a crash mid-write
/// never leaves a truncated archive behind.
///
/// Two archive objects: `lookup` is what was on disk at launch and is only read (handed to
/// pipeline descriptors, possibly from several compile threads at once); `writer` collects the
/// same plus every new pipeline and is the one serialized. Mutating an archive that concurrent
/// compiles are reading produced archives Metal could not serialize.
///
/// Metal can refuse to serialize an archive because of one pipeline in it (seen with WE's
/// `transform` effect next to the other built-ins: "expecting 'fragment' stage in pipeline no.
/// N"). A failed write is retried pipeline by pipeline from the last good file; a pipeline that
/// breaks it is left out and remembered in `<archive>.skip`, and still renders, just compiled
/// normally.
///
/// Thread-safe: `lock` owns `writer`, `pending`, `skipped`, `serializeScheduled` and the
/// counters; `serializeQueue` runs writes one at a time; `lookup` is immutable.
final class EffectPipelineArchive {
    /// Bump when what goes into the archive changes (e.g. descriptor fields).
    static let revision = 1

    let url: URL
    private let skipURL: URL
    private let device: MTLDevice
    private let lock = NSLock()
    private let lookup: MTLBinaryArchive?
    private var writer: MTLBinaryArchive?
    /// Pipelines added since the last successful write, by key.
    private var pending: [(key: String, descriptor: MTLRenderPipelineDescriptor)] = []
    /// Keys of pipelines that make the archive unserializable.
    private var skipped: Set<String>
    private var writeFailureCount = 0
    private var hitCount = 0
    private var additionCount = 0
    /// Pipelines served from the archive / added to it, for tests and diagnostics.
    var hits: Int { lock.withLock { hitCount } }
    var additions: Int { lock.withLock { additionCount } }
    /// Writes that failed even after leaving out unserializable pipelines.
    var writeFailures: Int { lock.withLock { writeFailureCount } }
    var skippedCount: Int { lock.withLock { skipped.count } }
    private var serializeScheduled = false
    private let serializeQueue = DispatchQueue(label: "owe.effect-pipeline-archive", qos: .utility)
    /// Writes wait this long after the last addition, so a burst of compiles writes once.
    let serializeDelay: TimeInterval

    init(device: MTLDevice, directory: URL, serializeDelay: TimeInterval = 2) {
        self.device = device
        self.serializeDelay = serializeDelay
        let prefix = Self.devicePrefix(device)
        url = directory.appending(path: "\(prefix)--\(Self.environmentKey).binarchive")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            OWELog.error(.shader, "Could not create the pipeline archive directory \(directory.path): \(error)")
        }
        Self.deleteStale(in: directory, deviceName: Self.deviceName(device), prefix: prefix, keeping: url)
        skipURL = url.appendingPathExtension("skip")
        skipped = Self.loadSkipped(skipURL)
        lookup = Self.open(url, device: device)
        writer = Self.open(url, device: device) ?? Self.makeEmpty(device)
    }

    static var defaultDirectory: URL? {
        ShaderVariantTranslator.defaultCacheDirectory?.deletingLastPathComponent()
            .appending(path: "pipeline-archives", directoryHint: .isDirectory)
    }

    /// The archives to put on a pipeline descriptor (`binaryArchives`), empty without one.
    var archives: [MTLBinaryArchive] { lookup.map { [$0] } ?? [] }

    /// Records a pipeline that compiled, and schedules a write. `key` identifies the pipeline
    /// across launches.
    func add(_ descriptor: MTLRenderPipelineDescriptor, key: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let writer, !skipped.contains(key) else { return }
        // The writer must not be referenced by what it records.
        let recorded = descriptor.copy() as! MTLRenderPipelineDescriptor // copy() of this class returns its own type
        recorded.binaryArchives = nil
        do {
            try writer.addRenderPipelineFunctions(descriptor: recorded)
            pending.append((key, recorded))
            additionCount += 1
        } catch {
            OWELog.error(.shader, "Could not add an effect pipeline to the binary archive: \(error)")
            return
        }
        guard !serializeScheduled else { return }
        serializeScheduled = true
        serializeQueue.asyncAfter(deadline: .now() + serializeDelay) { [weak self] in
            self?.serialize()
        }
    }

    func recordHit() {
        lock.withLock { hitCount += 1 }
    }

    /// Writes pending additions now (tests, app termination).
    func flush() {
        serializeQueue.sync { serialize() }
    }

    private func serialize() {
        lock.lock()
        defer { lock.unlock() }
        serializeScheduled = false
        guard !pending.isEmpty, let writer else { return }
        do {
            try write(writer)
            pending.removeAll()
        } catch {
            OWELog.error(.shader, "Could not write the effect pipeline archive \(url.path): \(error); "
                         + "retrying pipeline by pipeline")
            recover()
        }
    }

    /// Rebuilds the writer from the last good file, adding the pending pipelines one at a time
    /// and leaving out each one Metal can't serialize.
    private func recover() {
        let batch = pending
        pending.removeAll()
        var accepted: [MTLRenderPipelineDescriptor] = []
        func rebuilt() -> MTLBinaryArchive? {
            guard let archive = Self.open(url, device: device) ?? Self.makeEmpty(device) else { return nil }
            for descriptor in accepted {
                do {
                    try archive.addRenderPipelineFunctions(descriptor: descriptor)
                } catch {
                    OWELog.error(.shader, "Could not re-add an effect pipeline to the binary archive: \(error)")
                }
            }
            return archive
        }
        var current = rebuilt()
        for (key, descriptor) in batch {
            guard let archive = current else { break }
            do {
                try archive.addRenderPipelineFunctions(descriptor: descriptor)
                try write(archive)
                accepted.append(descriptor)
            } catch {
                OWELog.error(.shader, "Leaving pipeline \(key.prefix(24)) out of the binary archive: \(error)")
                skipped.insert(key)
                current = rebuilt()
            }
        }
        writer = current
        if writer == nil { writeFailureCount += 1 }
        saveSkipped()
    }

    /// Serializes `archive` to a temporary file and renames it over `url`.
    private func write(_ archive: MTLBinaryArchive) throws {
        let temporary = url.deletingLastPathComponent()
            .appending(path: ".\(url.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier).tmp")
        do {
            try archive.serialize(to: temporary)
            if rename(temporary.path, url.path) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary) // best-effort cleanup of our own temp file
            throw error
        }
    }

    private static func loadSkipped(_ url: URL) -> Set<String> {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            return Set(try JSONDecoder().decode([String].self, from: Data(contentsOf: url)))
        } catch {
            OWELog.error(.shader, "Ignoring unreadable \(url.path): \(error)")
            return []
        }
    }

    private func saveSkipped() {
        guard !skipped.isEmpty else { return }
        do {
            try JSONEncoder().encode(skipped.sorted()).write(to: skipURL, options: .atomic)
        } catch {
            OWELog.error(.shader, "Could not write \(skipURL.path): \(error)")
        }
    }

    /// The archive at `url`, or nil when there is none or Metal can't open it (then it is deleted).
    private static func open(_ url: URL, device: MTLDevice) -> MTLBinaryArchive? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let descriptor = MTLBinaryArchiveDescriptor()
        descriptor.url = url
        do {
            return try device.makeBinaryArchive(descriptor: descriptor)
        } catch {
            OWELog.error(.shader, "Discarding unreadable effect pipeline archive \(url.path): \(error)")
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                OWELog.error(.shader, "Could not delete \(url.path): \(error)")
            }
            return nil
        }
    }

    private static func makeEmpty(_ device: MTLDevice) -> MTLBinaryArchive? {
        do {
            return try device.makeBinaryArchive(descriptor: MTLBinaryArchiveDescriptor())
        } catch {
            OWELog.error(.shader, "Could not create an effect pipeline archive: \(error)")
            return nil
        }
    }

    // MARK: - Keys

    static func deviceName(_ device: MTLDevice) -> String {
        String(device.name.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    static func devicePrefix(_ device: MTLDevice) -> String {
        "\(deviceName(device))-\(String(device.registryID, radix: 16))"
    }

    /// OS build, app version and build, archive revision.
    static var environmentKey: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
            .map { $0.isLetter || $0.isNumber || $0 == "." ? $0 : "_" }
        return "\(String(os))--\(version)-\(build)--r\(revision)"
    }

    /// How long an archive of another instance of the same GPU model (a registry ID that changed
    /// after a reboot or re-plug) is kept before it counts as abandoned.
    static let abandonedAge: TimeInterval = 30 * 24 * 3600

    /// Deletes this GPU's archives for another OS or app build, and abandoned ones of the same model.
    private static func deleteStale(in directory: URL, deviceName: String, prefix: String, keeping url: URL) {
        let fileManager = FileManager.default
        // Optional: an unreadable directory just means there is nothing to prune.
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(deviceName) && name != url.lastPathComponent
            && name != url.lastPathComponent + ".skip" {
            let path = directory.appending(path: name)
            if !name.hasPrefix("\(prefix)--") {
                // Optional: without a date the file is left alone.
                let modified = (try? fileManager.attributesOfItem(atPath: path.path))?[.modificationDate] as? Date
                guard let modified, Date().timeIntervalSince(modified) > abandonedAge else { continue }
            }
            do {
                try fileManager.removeItem(at: path)
            } catch {
                OWELog.error(.shader, "Could not delete the stale pipeline archive \(name): \(error)")
            }
        }
    }
}
