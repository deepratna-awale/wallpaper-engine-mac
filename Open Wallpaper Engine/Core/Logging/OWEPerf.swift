import Foundation
import QuartzCore
import os

/// Severity-gated logging plus near-zero-cost signposts and per-frame counters.
/// Signposts are always emitted: `os_signpost` compiles to a no-op unless Instruments is recording.
enum OWELog {
    enum Severity: Int, Comparable {
        case debug = 0, info = 1, error = 2, silent = 3
        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    enum Category: String {
        case scene = "SceneVM"
        case script = "SceneScript"
        case audio = "AudioCapture"
        case shader = "ShaderTranslator"
        case importer = "Import"
        case workshop = "Workshop"
        case texture = "TEXParser"
        case perf = "Perf"
    }

    /// Debug builds never rise above `.info`, so lifecycle diagnostics stay visible during development.
    nonisolated(unsafe) static var minimumSeverity: Severity = {
        #if DEBUG
        return .info
        #else
        return .error
        #endif
    }()

    static func apply(logLevel: GSLogLevel) {
        let requested: Severity
        switch logLevel {
        case .none: requested = .error
        case .error: requested = .error
        case .verbose: requested = .debug
        }
        #if DEBUG
        minimumSeverity = min(requested, .info)
        #else
        minimumSeverity = requested
        #endif
        OWEFrameMetrics.isReportingEnabled = (logLevel == .verbose) || OWEFrameMetrics.defaultsEnabled
    }

    static func debug(_ category: Category, _ message: @autoclosure () -> String) {
        emit(.debug, category, message)
    }

    static func info(_ category: Category, _ message: @autoclosure () -> String) {
        emit(.info, category, message)
    }

    static func error(_ category: Category, _ message: @autoclosure () -> String) {
        emit(.error, category, message)
    }

    private static func emit(_ severity: Severity,
                             _ category: Category,
                             _ message: () -> String) {
        guard severity >= minimumSeverity else { return }
        NSLog("%@", "[\(category.rawValue)] \(message())")
    }
}

enum OWESignpost {
    static let subsystem = "com.winddog.wallpaper-engine"

    static let render = OSLog(subsystem: subsystem, category: "Render")
    static let scene = OSLog(subsystem: subsystem, category: "Scene")
    static let audio = OSLog(subsystem: subsystem, category: "Audio")

    /// Scoped signpost interval. Hold the returned token; the interval ends when it deinits.
    struct Interval {
        let log: OSLog
        let name: StaticString
        let id: OSSignpostID

        init(_ log: OSLog, _ name: StaticString) {
            self.log = log
            self.name = name
            self.id = OSSignpostID(log: log)
            os_signpost(.begin, log: log, name: name, signpostID: id)
        }

        func end() {
            os_signpost(.end, log: log, name: name, signpostID: id)
        }
    }

    static func begin(_ log: OSLog, _ name: StaticString) -> Interval {
        Interval(log, name)
    }

    static func event(_ log: OSLog, _ name: StaticString) {
        os_signpost(.event, log: log, name: name)
    }
}

/// Diagnostic counters. Increments race benignly across threads by design; these values are
/// indicative, never load-bearing, and cost one predictable branch when reporting is disabled.
enum OWEFrameMetrics {
    static let defaultsEnabled: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    nonisolated(unsafe) static var isReportingEnabled = defaultsEnabled

    nonisolated(unsafe) private static var frameCount = 0
    nonisolated(unsafe) private static var accumulatedFrameSeconds = 0.0
    nonisolated(unsafe) private static var worstFrameSeconds = 0.0
    nonisolated(unsafe) private static var lastReportTime = CACurrentMediaTime()

    nonisolated(unsafe) private static var lockAcquisitions = 0
    nonisolated(unsafe) private static var scriptEvaluations = 0
    nonisolated(unsafe) private static var sceneReloads = 0
    nonisolated(unsafe) private static var textureDecodes = 0
    nonisolated(unsafe) private static var layersDrawn = 0
    nonisolated(unsafe) private static var particlesUpdated = 0
    nonisolated(unsafe) private static var effectStackBuilds = 0

    static func countLockAcquisition() {
        guard isReportingEnabled else { return }
        lockAcquisitions &+= 1
    }

    static func countScriptEvaluation() {
        guard isReportingEnabled else { return }
        scriptEvaluations &+= 1
    }

    static func countSceneReload() {
        guard isReportingEnabled else { return }
        sceneReloads &+= 1
    }

    static func countTextureDecode() {
        guard isReportingEnabled else { return }
        textureDecodes &+= 1
    }

    static func countEffectStackBuild() {
        guard isReportingEnabled else { return }
        effectStackBuilds &+= 1
    }

    static func recordFrame(seconds: Double, layers: Int, particles: Int) {
        guard isReportingEnabled else { return }
        frameCount &+= 1
        accumulatedFrameSeconds += seconds
        worstFrameSeconds = max(worstFrameSeconds, seconds)
        layersDrawn &+= layers
        particlesUpdated &+= particles

        let now = CACurrentMediaTime()
        guard now - lastReportTime >= 2 else { return }
        report(elapsed: now - lastReportTime)
        lastReportTime = now
    }

    private static func report(elapsed: Double) {
        guard frameCount > 0 else { return }
        let averageMs = accumulatedFrameSeconds / Double(frameCount) * 1000
        let worstMs = worstFrameSeconds * 1000
        let fps = Double(frameCount) / elapsed
        let perFrame = { (value: Int) in Double(value) / Double(frameCount) }

        OWELog.info(.perf, String(format:
            "fps %.1f | frame avg %.2fms p-worst %.2fms | layers/f %.1f particles/f %.0f | locks/f %.1f scripts/f %.1f | stacks/f %.2f | reloads %d texDecodes %d",
            fps, averageMs, worstMs,
            perFrame(layersDrawn), perFrame(particlesUpdated),
            perFrame(lockAcquisitions), perFrame(scriptEvaluations),
            perFrame(effectStackBuilds),
            sceneReloads, textureDecodes))

        frameCount = 0
        accumulatedFrameSeconds = 0
        worstFrameSeconds = 0
        lockAcquisitions = 0
        scriptEvaluations = 0
        layersDrawn = 0
        particlesUpdated = 0
        effectStackBuilds = 0
        sceneReloads = 0
        textureDecodes = 0
    }
}
