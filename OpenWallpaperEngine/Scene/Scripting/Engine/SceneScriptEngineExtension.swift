import Foundation
import JavaScriptCore

/// WP4 of docs/scenescript-plan.md: the `engine`, `input` and `console` globals,
/// `engine.setTimeout`/`setInterval`, `engine.openUserShortcut` and the conversion of user
/// properties through WE's `_Internal.convertUserProperties`.
///
/// Per-frame numbers (`frametime`, `runtime`, `timeOfDay`, sizes, the cursor) sit in one shared
/// `Float32Array` (float, like WE's own) that JS getters read, so a frame costs no bridging.
/// Console and user shortcuts are narrow native functions on `__rt.native`.
/// Confined to the runtime's thread, like the runtime; `environment` and `input` are set there.
final class SceneScriptEngineExtension: SceneScriptRuntimeExtension {
    /// Slots of the shared frame buffer (`__rt.native.engineFrame`); mirrored in sceneScriptEngine.js.
    enum Slot {
        static let frametime = 0
        static let runtime = 1
        static let timeOfDay = 2
        static let screenResolution = 3
        static let canvasSize = 5
        static let cursorWorldPosition = 7
        static let cursorScreenPosition = 10
        static let cursorLeftDown = 12
        static let isScreensaver = 13
        static let isRunningInEditor = 14
        static let count = 16
    }

    let scriptResources = ["sceneScriptEngine", "sceneScriptConsole", "sceneScriptTimers"]

    var environment: SceneScriptEngineEnvironment {
        didSet { publish() }
    }

    var input = SceneScriptInput() {
        didSet { publish() }
    }

    /// Runs the user shortcut bound to a `usershortcut` user property; true when it ran. Nil
    /// until the app supports user shortcuts: `engine.openUserShortcut` then logs once per
    /// property and returns false.
    var userShortcutHandler: ((String) -> Bool)?

    /// `engine.runtime`: seconds of scene time since the runtime started.
    private(set) var runtimeSeconds = 0.0

    private let now: () -> Date
    private let calendar: Calendar
    private let consoleSink: SceneScriptConsole.Sink
    private var frame: SceneScriptSharedBuffer<Float>?
    private var frametime = 0.0
    private var unsupportedShortcuts = Set<String>()

    init(environment: SceneScriptEngineEnvironment = .standard,
         now: @escaping () -> Date = Date.init, calendar: Calendar = .current,
         consoleSink: @escaping SceneScriptConsole.Sink = SceneScriptConsole.log) {
        self.environment = environment
        self.now = now
        self.calendar = calendar
        self.consoleSink = consoleSink
    }

    // MARK: - SceneScriptRuntimeExtension

    func install(into runtime: SceneScriptRuntime) throws {
        guard let frame = SceneScriptSharedBuffer<Float>(count: Slot.count, in: runtime.context) else {
            throw SceneScriptRuntime.CreationError(description: "the engine frame buffer could not be allocated")
        }
        guard let native = runtime.rt.forProperty("native"), native.isObject else {
            throw SceneScriptRuntime.CreationError(description: "runtime.js has no __rt.native")
        }
        self.frame = frame
        publish()
        native.setValue(frame.value, forProperty: "engineFrame")
        installConsole(on: native, identity: runtime.identity)
        let openUserShortcut: @convention(block) (String) -> Bool = { [weak self] name in
            self?.openUserShortcut(name) ?? false
        }
        native.setValue(unsafeBitCast(openUserShortcut, to: AnyObject.self), forProperty: "engineOpenUserShortcut")
    }

    func willRunFrame(_ runtime: SceneScriptRuntime, deltaTime: Double) {
        frametime = deltaTime
        runtimeSeconds += deltaTime
        publish()
    }

    // MARK: - Frame buffer

    /// Writes the current numbers into the shared buffer. Called at install (so module bodies and
    /// `init` see real sizes), whenever `environment` or `input` change, and before every frame.
    private func publish() {
        guard let frame else { return }
        frame[Slot.frametime] = Float(frametime)
        frame[Slot.runtime] = Float(runtimeSeconds)
        frame[Slot.timeOfDay] = Float(timeOfDay())
        frame[Slot.screenResolution] = Float(environment.screenResolution.x)
        frame[Slot.screenResolution + 1] = Float(environment.screenResolution.y)
        frame[Slot.canvasSize] = Float(environment.canvasSize.x)
        frame[Slot.canvasSize + 1] = Float(environment.canvasSize.y)
        let world = input.cursorWorldPosition(in: environment)
        frame[Slot.cursorWorldPosition] = Float(world.x)
        frame[Slot.cursorWorldPosition + 1] = Float(world.y)
        frame[Slot.cursorWorldPosition + 2] = 0
        frame[Slot.cursorScreenPosition] = Float(input.cursorScreenPosition.x)
        frame[Slot.cursorScreenPosition + 1] = Float(input.cursorScreenPosition.y)
        frame[Slot.cursorLeftDown] = input.cursorLeftDown ? 1 : 0
        frame[Slot.isScreensaver] = environment.isScreensaver ? 1 : 0
        frame[Slot.isRunningInEditor] = environment.isRunningInEditor ? 1 : 0
    }

    /// `engine.timeOfDay`: the local wall clock as a fraction of 24 h, 00:00:00 → 0.
    private func timeOfDay() -> Double {
        let parts = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: now())
        let seconds = Double((parts.hour ?? 0) * 3600 + (parts.minute ?? 0) * 60 + (parts.second ?? 0))
            + Double(parts.nanosecond ?? 0) / 1_000_000_000
        return seconds / 86_400
    }

    // MARK: - Native functions

    /// `__rt.native.consoleWrite(isError, message, scriptID)`.
    private func installConsole(on native: JSValue, identity: SceneScriptIdentity) {
        let console = SceneScriptConsole(identity: identity, sink: consoleSink)
        let write: @convention(block) (Bool, String, String) -> Void = { [weak self] isError, message, scriptID in
            console.write(isError ? .error : .log, message: message, scriptID: scriptID,
                          time: self?.runtimeSeconds ?? 0)
        }
        native.setValue(unsafeBitCast(write, to: AnyObject.self), forProperty: "consoleWrite")
    }

    /// The native half of `engine.openUserShortcut`; the JS half enforces WE's cursor-callback rules.
    private func openUserShortcut(_ name: String) -> Bool {
        if let userShortcutHandler { return userShortcutHandler(name) }
        if unsupportedShortcuts.insert(name).inserted {
            OWELog.info(.script, "engine.openUserShortcut('\(name)'): user shortcuts are not supported yet")
        }
        return false
    }
}
