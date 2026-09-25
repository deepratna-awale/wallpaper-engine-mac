import Foundation

/// Detects an app crash inside the in-process shader compiler and turns it off afterwards.
///
/// A glslang abort used to kill only a `glslangValidator` process; in-process it kills the app,
/// and the same wallpaper would crash it again on every launch. While a compile runs, a
/// `pending-<pid>` file exists in `directory`. A pending file whose process is gone on the next
/// launch means that process died mid-compile, so in-process compiling is disabled for that
/// library build (the process compiler takes over) until the linked libraries change.
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

    /// Checks for markers left by dead processes and records a crash against `fingerprint`.
    /// Returns whether in-process compiling may be used with these libraries.
    func allowsInProcess(fingerprint: String) -> Bool {
        let fileManager = FileManager.default
        // Optional: no directory yet means nothing ever crashed here.
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix("pending-") {
            guard let owner = Int32(name.dropFirst("pending-".count)), !Self.isAlive(owner) else { continue }
            OWELog.error(.shader, "A previous run (pid \(owner)) died while compiling a shader in-process; "
                         + "using the glslang/spirv-cross processes until the shader libraries change")
            do {
                try Data(fingerprint.utf8).write(to: disabledURL, options: .atomic)
                try fileManager.removeItem(at: directory.appending(path: name))
            } catch {
                OWELog.error(.shader, "Could not record the in-process shader compiler crash: \(error)")
            }
        }
        // Optional: a missing file means in-process compiling was never disabled.
        guard let disabled = try? Data(contentsOf: disabledURL) else { return true }
        return String(decoding: disabled, as: UTF8.self) != fingerprint
    }

    private static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
