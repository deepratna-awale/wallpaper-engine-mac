import Foundation
import Metal

/// An `MTLBinaryArchive` of effect pipeline states, kept in the cache directory so a later launch
/// skips the GPU backend compile of every pipeline it has seen.
///
/// One file per GPU (name and registry ID), OS build and app build: a binary compiled for one of
/// those is useless, or unsafe to hand the driver, under another. Files for the same GPU with an
/// older key are deleted. A file Metal refuses to open is deleted and replaced by an empty
/// archive. Writes go to a staging file that is renamed into place, so a crash mid-write
/// never leaves a truncated archive behind (see `write`).
///
/// Every write serializes a *fresh* archive holding every pipeline this session used: the ones
/// it compiled and the ones it found in the file from the last launch (`lookup`, which is only
/// read). Metal fails to serialize an archive that pipelines were added to after it was
/// serialized or loaded from disk, for some sets of pipelines ("missing 'vertex' stage" /
/// "expecting 'fragment' stage in pipeline no. N", first seen after WE's `transform`); the same
/// pipelines added to a new archive in one go always serialize. So the file holds the pipelines
/// of the last session that compiled something new, which also bounds its size.
///
/// A failed write is never retried in the same session. When writing the file fails inside
/// Metal (its destination directory deleted mid-write, disk full), `serialize(to:)` hands back an
/// `NSError` it has already freed, and retaining that crashes the process (SIGSEGV in
/// `objc_retain` under `-[_MTLBinaryArchive airntSerializeToURL:options:error:]`). Every failed
/// attempt is a chance of that crash, so the first failure keeps the file as it is until the next
/// launch.
///
/// Thread-safe: `lock` owns `recorded`, `recordedKeys`, `written`, `writesStopped`,
/// `serializeScheduled` and the counters; `serializeQueue` runs writes one at a
/// time and builds them outside the lock; `lookup` is immutable.
final class EffectPipelineArchive {
    /// Bump when what goes into the archive changes (e.g. descriptor fields).
    static let revision = 2

    let url: URL
    private let device: MTLDevice
    private let lock = NSLock()
    private let lookup: MTLBinaryArchive?
    /// Pipelines this session used, in first-use order, by key.
    private var recorded: [(key: String, descriptor: MTLRenderPipelineDescriptor)] = []
    private var recordedKeys = Set<String>()
    /// Whether the file holds every pipeline in `recorded`.
    private var written = true
    /// Set by a failed write: no further writes this session (see the type's comment).
    private var writesStopped = false
    private var writeCount = 0
    private var writeFailureCount = 0
    private var hitCount = 0
    private var additionCount = 0
    /// Pipelines served from the archive / added to it, for tests and diagnostics.
    var hits: Int { lock.withLock { hitCount } }
    var additions: Int { lock.withLock { additionCount } }
    /// Archives serialized to the file, and attempts that failed.
    var writes: Int { lock.withLock { writeCount } }
    var writeFailures: Int { lock.withLock { writeFailureCount } }
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
        lookup = Self.open(url, device: device)
    }

    deinit {
        // Pending pipelines of the last renderer to let go still reach the file.
        serialize()
    }

    /// Archives in use, one per device and directory. Every renderer of a device shares one, so
    /// they don't overwrite each other's file with their own subset of pipelines. Weak: an
    /// archive lives as long as some renderer holds it.
    ///
    /// Global by necessity (rule 3): the file is a process-wide resource, and the renderers that
    /// share it are created independently. `registryLock` owns `registry`.
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: WeakArchive] = [:] // guarded by registryLock

    private struct WeakArchive {
        weak var archive: EffectPipelineArchive?
    }

    /// The archive for `device` in `directory`, shared with every other caller that uses it.
    static func shared(device: MTLDevice, directory: URL) -> EffectPipelineArchive {
        let key = "\(device.registryID)|\(directory.standardizedFileURL.path)"
        return registryLock.withLock {
            if let archive = registry[key]?.archive { return archive }
            registry = registry.filter { $0.value.archive != nil }
            let archive = EffectPipelineArchive(device: device, directory: directory)
            registry[key] = WeakArchive(archive: archive)
            return archive
        }
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
        guard record(descriptor, key: key) else { return }
        additionCount += 1
        written = false
        guard !serializeScheduled, !writesStopped else { return }
        serializeScheduled = true
        serializeQueue.asyncAfter(deadline: .now() + serializeDelay) { [weak self] in
            self?.serialize()
        }
    }

    /// A pipeline served from the file: it goes into the next write too.
    func recordHit(_ descriptor: MTLRenderPipelineDescriptor, key: String) {
        lock.withLock {
            hitCount += 1
            _ = record(descriptor, key: key)
        }
    }

    /// Writes pending additions now (tests, app termination).
    func flush() {
        serializeQueue.sync { serialize() }
    }

    /// Adds to `recorded`; false when it is known. Caller holds `lock`.
    private func record(_ descriptor: MTLRenderPipelineDescriptor, key: String) -> Bool {
        guard recordedKeys.insert(key).inserted else { return false }
        // The copy keeps `lookup` so building the write can take binaries from it.
        let copy = descriptor.copy() as! MTLRenderPipelineDescriptor // copy() of this class returns its own type
        copy.binaryArchives = archives
        recorded.append((key, copy))
        return true
    }

    private func serialize() {
        let batch: [(key: String, descriptor: MTLRenderPipelineDescriptor)] = lock.withLock {
            serializeScheduled = false
            return written || writesStopped ? [] : recorded
        }
        guard !batch.isEmpty else { return }
        do {
            try write(try build(batch))
            lock.withLock {
                writeCount += 1
                // Pipelines recorded while this write was built make it stale again.
                written = recorded.count == batch.count
            }
        } catch {
            lock.withLock {
                writeFailureCount += 1
                writesStopped = true
            }
            OWELog.error(.shader, "Could not write the effect pipeline archive \(url.path): \(error); "
                         + "keeping the file as it is until the next launch")
        }
    }

    /// A new archive with `pipelines`, added in one go.
    private func build(_ pipelines: [(key: String, descriptor: MTLRenderPipelineDescriptor)]) throws -> MTLBinaryArchive {
        let archive = try device.makeBinaryArchive(descriptor: MTLBinaryArchiveDescriptor())
        for pipeline in pipelines {
            try archive.addRenderPipelineFunctions(descriptor: pipeline.descriptor)
        }
        return archive
    }

    /// Serializes `archive` to a staging file in the temporary directory, then moves it over
    /// `url`. Metal never writes into the archive's own directory: if that directory disappears
    /// while Metal writes into it (a cache purge, a test deleting its scratch directory),
    /// `serialize(to:)` returns an already freed error and the process crashes in `objc_retain`.
    /// A directory gone by the time of the move fails here, in Swift, instead. The staging name
    /// is unique per write, so two archives for one file never share it.
    private func write(_ archive: MTLBinaryArchive) throws {
        let staging = FileManager.default.temporaryDirectory
            .appending(path: "owe-pipeline-archive-\(UUID().uuidString).binarchive")
        defer { try? FileManager.default.removeItem(at: staging) } // best-effort cleanup; gone after a rename
        try archive.serialize(to: staging)
        if rename(staging.path, url.path) == 0 { return }
        guard errno == EXDEV else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        // Another volume: copy next to `url`, then rename, so the file is never seen half-written.
        let temporary = url.deletingLastPathComponent()
            .appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try FileManager.default.copyItem(at: staging, to: temporary)
            if rename(temporary.path, url.path) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary) // best-effort cleanup of our own temp file
            throw error
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
