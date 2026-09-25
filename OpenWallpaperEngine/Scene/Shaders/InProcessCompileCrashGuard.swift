import Foundation

/// Detects an app crash inside the in-process shader compiler and turns it off afterwards.
///
/// A glslang abort used to kill only a `glslangValidator` process; in-process it kills the app,
/// and the same wallpaper would crash it again on every launch. While a compile runs, a
/// `pending-<pid>` file exists in `directory`. A pending file whose process is gone on the next
/// launch means that process died mid-compile. After `disableThreshold` such deaths,
/// in-process compiling is disabled for that library build (the process compiler takes over,
/// when it is installed) until the linked libraries change.
///
/// Separate from the app's safe-restart ledger (`SafeRestartLedger`), which reacts to the same
/// crash per wallpaper (not restoring it); this one reacts per shader library build. Neither
/// reads or writes the other's files.
///
/// Thread-safe: `lock` owns `depth`.
final class InProcessCompileCrashGuard {
    let directory: URL
    private let pid: Int32
    private let lock = NSLock()
    private var depth = 0

    init(directory: URL, pid: Int32 = ProcessInfo.processInfo.processIdentifier) {
        self.directory = directory
        self.pid = pid
    }

    private var pendingURL: URL { directory.appending(path: "pending-\(pid)") }
    private var disabledURL: URL { directory.appending(path: "disabled") }

    func begin() {
        lock.lock()
        defer { lock.unlock() }
        depth += 1
        guard depth == 1 else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data().write(to: pendingURL)
        } catch {
            OWELog.error(.shader, "Could not write the shader compile marker \(pendingURL.path): \(error)")
        }
    }

    func end() {
        lock.lock()
        defer { lock.unlock() }
        depth -= 1
        guard depth == 0 else { return }
        do {
            try FileManager.default.removeItem(at: pendingURL)
        } catch {
            OWELog.error(.shader, "Could not remove the shader compile marker \(pendingURL.path): \(error)")
        }
    }

    /// Deaths mid-compile with the same libraries that turn in-process compiling off. One is not
    /// enough: a force quit, logout or power loss during a compile leaves the same marker as a
    /// crash. They are not forgiven by clean runs, because safe restart keeps a crashing wallpaper
    /// from loading on the next launch, so its crashes are rarely consecutive.
    static let disableThreshold = 2

    /// What `disabled` records: the libraries and how many deaths mid-compile they have had.
    private struct Record: Codable {
        var fingerprint: String
        var deaths: Int
    }

    /// Checks for markers left by dead processes and records a death against `fingerprint`.
    /// Returns whether in-process compiling may be used with these libraries.
    func allowsInProcess(fingerprint: String) -> Bool {
        let fileManager = FileManager.default
        var record = loadRecord()
        if record?.fingerprint != fingerprint { record = Record(fingerprint: fingerprint, deaths: 0) }
        // Optional: no directory yet means nothing ever crashed here.
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        var died = false
        for name in names where name.hasPrefix("pending-") {
            guard let owner = Int32(name.dropFirst("pending-".count)), !Self.isAlive(owner) else { continue }
            died = true
            do {
                try fileManager.removeItem(at: directory.appending(path: name))
            } catch {
                OWELog.error(.shader, "Could not remove the stale shader compile marker \(name): \(error)")
            }
        }
        if died {
            record!.deaths += 1
            OWELog.error(.shader, "A previous run died while compiling a shader in-process "
                         + "(\(record!.deaths) with these libraries)")
            save(record!)
        }
        let allowed = record!.deaths < Self.disableThreshold
        if !allowed {
            OWELog.error(.shader, "In-process shader compiling is off until the shader libraries change")
        }
        return allowed
    }

    private func loadRecord() -> Record? {
        // Optional: a missing file means nothing died mid-compile.
        guard let data = try? Data(contentsOf: disabledURL) else { return nil }
        do {
            return try JSONDecoder().decode(Record.self, from: data)
        } catch {
            // The previous format held only the fingerprint of disabled libraries.
            return Record(fingerprint: String(decoding: data, as: UTF8.self), deaths: Self.disableThreshold)
        }
    }

    private func save(_ record: Record) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(record).write(to: disabledURL, options: .atomic)
        } catch {
            OWELog.error(.shader, "Could not record the in-process shader compiler state: \(error)")
        }
    }

    private static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
