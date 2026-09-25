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
/// Thread-safe: `lock` owns `archive`, `dirty`, `serializeScheduled` and the counters; `serializeQueue` runs writes one at a time.
final class EffectPipelineArchive {
    /// Bump when what goes into the archive changes (e.g. descriptor fields).
    static let revision = 1

    let url: URL
    private let device: MTLDevice
    private let lock = NSLock()
    private var archive: MTLBinaryArchive?
    private var dirty = false
    private var hitCount = 0
    private var additionCount = 0
    /// Pipelines served from the archive / added to it, for tests and diagnostics.
    var hits: Int { lock.withLock { hitCount } }
    var additions: Int { lock.withLock { additionCount } }
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
        archive = open()
    }

    static var defaultDirectory: URL? {
        ShaderVariantTranslator.defaultCacheDirectory?.deletingLastPathComponent()
            .appending(path: "pipeline-archives", directoryHint: .isDirectory)
    }

    /// The archives to put on a pipeline descriptor (`binaryArchives`), empty without one.
    var archives: [MTLBinaryArchive] {
        lock.withLock { archive.map { [$0] } ?? [] }
    }

    /// Records a pipeline that compiled, and schedules a write.
    func add(_ descriptor: MTLRenderPipelineDescriptor) {
        lock.lock()
        defer { lock.unlock() }
        guard let archive else { return }
        do {
            try archive.addRenderPipelineFunctions(descriptor: descriptor)
            dirty = true
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
        guard dirty, let archive else { return }
        let temporary = url.deletingLastPathComponent()
            .appending(path: ".\(url.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier).tmp")
        do {
            try archive.serialize(to: temporary)
            if rename(temporary.path, url.path) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            dirty = false
        } catch {
            OWELog.error(.shader, "Could not write the effect pipeline archive \(url.path): \(error)")
            try? FileManager.default.removeItem(at: temporary) // best-effort cleanup of our own temp file
        }
    }

    private func open() -> MTLBinaryArchive? {
        let descriptor = MTLBinaryArchiveDescriptor()
        if FileManager.default.fileExists(atPath: url.path) {
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
                descriptor.url = nil
            }
        }
        do {
            return try device.makeBinaryArchive(descriptor: descriptor)
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
        for name in names where name.hasPrefix(deviceName) && name != url.lastPathComponent {
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
