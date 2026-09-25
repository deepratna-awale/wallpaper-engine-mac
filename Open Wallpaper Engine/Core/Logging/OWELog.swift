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
        case app = "App"
        case library = "Library"
        case web = "Web"
        case settings = "Settings"
        case ui = "UI"
    }

    private static let loggers: [Category: Logger] = Dictionary(uniqueKeysWithValues: [
        Category.scene, .script, .audio, .shader, .importer, .workshop, .texture, .perf,
        .app, .library, .web, .settings, .ui
    ].map { ($0, Logger(subsystem: "com.winddog.wallpaper-engine", category: $0.rawValue)) })

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
        guard severity >= minimumSeverity, let logger = loggers[category] else { return }
        // Public: these messages carry paths and effect names, which the unified log would
        // otherwise redact to <private> and make useless for diagnosing a wallpaper.
        let text = message()
        switch severity {
        case .debug: logger.debug("\(text, privacy: .public)")
        case .info: logger.info("\(text, privacy: .public)")
        case .error: logger.error("\(text, privacy: .public)")
        case .silent: break
        }
    }
}
