import Foundation
import JavaScriptCore
import XCTest
@testable import OpenWallpaperEngine

/// Like `TestSceneScriptCompiler`, but exports every callback WE calls (cursor and media too), so
/// tests can drive them with `__rt.broadcast`. Plain function declarations only; lines are kept.
struct AllCallbacksTestSceneScriptCompiler: SceneScriptModuleCompiling {
    private static let exportNames = ["init", "update", "destroy", "resizeScreen", "applyUserProperties",
                                      "applyGeneralSettings", "cursorEnter", "cursorLeave", "cursorMove",
                                      "cursorDown", "cursorUp", "cursorClick", "mediaStatusChanged",
                                      "mediaPlaybackChanged", "mediaPropertiesChanged", "mediaThumbnailChanged",
                                      "mediaTimelineChanged", "animationEvent", "scriptProperties"]

    func compile(_ source: String) throws -> SceneScriptCompiledModule {
        let getters = Self.exportNames
            .map { "get \($0)() { return typeof \($0) === 'undefined' ? undefined : \($0); }" }
            .joined(separator: ", ")
        let header = "(function (__rt, __scope) { 'use strict'; var thisLayer = __scope.thisLayer, thisObject = __scope.thisObject; "
        return SceneScriptCompiledModule(factorySource: header + source + "\nreturn { \(getters) }; })")
    }
}

/// A runtime with the WP4 extension, plus helpers.
final class SceneScriptEngineTestFixture {
    let host: TestSceneScriptHost
    let engine: SceneScriptEngineExtension
    let runtime: SceneScriptRuntime
    private(set) var consoleLines: [(SceneScriptConsole.Level, String)] = []

    init(wallpaperID: String = "test-wallpaper", screenID: String = "screen-1",
         environment: SceneScriptEngineEnvironment = .standard,
         now: @escaping () -> Date = Date.init, calendar: Calendar = .current) throws {
        host = TestSceneScriptHost(wallpaperID: wallpaperID, screenID: screenID)
        var sink: SceneScriptConsole.Sink = { _, _ in }
        let engine = SceneScriptEngineExtension(environment: environment, now: now,
                                                calendar: calendar, consoleSink: { sink($0, $1) })
        self.engine = engine
        runtime = try SceneScriptRuntime(host: host, compiler: AllCallbacksTestSceneScriptCompiler(),
                                         extensions: [engine])
        sink = { [weak self] level, line in self?.consoleLines.append((level, line)) }
    }

    func add(_ id: String, _ source: String, initialValue: Any = NSNull()) {
        runtime.add(SceneScriptInstance(id: id, source: source, initialValue: initialValue))
    }

    @discardableResult
    func evaluate(_ script: String) -> JSValue? {
        runtime.context.evaluateScript(script)
    }

    /// `shared.log`, emptied.
    func takeLog() -> [String] {
        evaluate("(shared.log || []).splice(0)")?.toArray() as? [String] ?? []
    }

    func frames(_ count: Int, deltaTime: Double = 1.0 / 60) {
        for _ in 0..<count { runtime.frame(deltaTime: deltaTime) }
    }
}
