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
