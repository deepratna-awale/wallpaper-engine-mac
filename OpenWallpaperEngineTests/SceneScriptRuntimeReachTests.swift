import JavaScriptCore
import XCTest
@testable import OpenWallpaperEngine

/// The runtime findings still open after the hardening (docs/test-risks.md): S11, a command a
/// handler pushes while the ring drains.
final class SceneScriptRuntimeReachTests: XCTestCase {
    private func evaluate(_ script: String, in runtime: SceneScriptRuntime) -> JSValue? {
        runtime.context.evaluateScript(script)
    }

    // MARK: - S11

    func testACommandPushedWhileTheRingDrainsRunsInTheSameDrain() throws {
        let runtime = try SceneScriptRuntime(host: TestSceneScriptHost(), compiler: TestSceneScriptCompiler())
        var log: [String] = []
        runtime.commandRing.register(SceneScriptCommandRing.Opcode(rawValue: 1002)) { [weak runtime] command in
            log.append("outer \(command.strings.first ?? "")")
            // A handler that calls back into JavaScript, like createLayer running a new layer's code.
            runtime?.rt.invokeMethod("push", withArguments: [1003, -1, [7], ["inner"]])
        }
        runtime.commandRing.register(SceneScriptCommandRing.Opcode(rawValue: 1003)) { command in
            log.append("\(command.strings.first ?? "") \(command.numbers.first ?? -1)")
        }
        runtime.add(SceneScriptInstance(id: "s", source: "function update() { __rt.push(1002, -1, [], ['a']); }"))
        runtime.load()
        runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(log, ["outer a", "inner 7.0"])
        XCTAssertEqual(runtime.commandRing.pendingCount, 0)
        runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(log, ["outer a", "inner 7.0", "outer a", "inner 7.0"], "nothing is replayed")
    }

    func testAHandlerThatKeepsPushingEndsInTheOverflow() throws {
        var configuration = SceneScriptRuntime.Configuration.standard
        configuration.commandCapacity = 16
        let runtime = try SceneScriptRuntime(host: TestSceneScriptHost(), compiler: TestSceneScriptCompiler(),
                                             configuration: configuration)
        var count = 0
        runtime.commandRing.register(SceneScriptCommandRing.Opcode(rawValue: 1004)) { [weak runtime] _ in
            count += 1
            runtime?.rt.invokeMethod("push", withArguments: [1004, -1])
        }
        runtime.add(SceneScriptInstance(id: "s", source: "function update() { __rt.push(1004, -1); }"))
        runtime.load()
        runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(count, 16, "bounded by the ring's capacity")
        XCTAssertEqual(runtime.commandRing.pendingCount, 0)
    }
}
