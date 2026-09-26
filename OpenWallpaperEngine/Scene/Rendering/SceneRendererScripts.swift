import Foundation
import simd

/// The renderer's side of SceneScript (docs/scenescript-plan.md WP11): owns the wallpaper
/// instance's `SceneScriptWallpaper`, keeps the state its last frame left, and answers the
/// renderer's questions about it (is an object visible, where is it, what does its text say, in
/// which order is it drawn). Main thread, like the renderer.
final class SceneRendererScripts {
    /// The app-wide script services; nil runs no scripts (tests that don't need them).
    let services: SceneScriptServices?
    /// The display this renderer draws on (`localStorage` `'screen'`, logs).
    let screenID: String
    /// Told once, on the main thread, when the watchdog stopped this wallpaper's scripts.
    var onHalt: ((SceneScriptError?) -> Void)?

    private(set) var wallpaper: SceneScriptWallpaper?
    private(set) var state = SceneScriptFrameState()
    /// The render thread's share of the scripts' cost: taking their state and handing them the
    /// frame, in milliseconds of CPU time, every frame (bounded), for measurements.
    private(set) var bridgeMilliseconds: [Double] = []
    private var content: SceneScriptSceneContent?
    /// Base (authored or user-bound) `visible` of every object, by id.
    private var baseVisibility: [String: Bool] = [:]
    /// Objects' parents, for visibility.
    private var parents: [String: String] = [:]
    private var lastScreenSize: SIMD2<Double>?

    init(services: SceneScriptServices?, screenID: String) {
        self.services = services
        self.screenID = screenID
    }

    // MARK: - Content

    /// Runs the scripts of new content: keeps the running scripts when the content was rebuilt
    /// from the same document (a user property changed a layer; scripts go on, as in WE), starts
    /// new ones otherwise. Nil stops them.
    func setContent(_ content: SceneScriptSceneContent?, visibility: [String: Bool], parents: [String: String]) {
        baseVisibility = visibility
        self.parents = parents
        if let wallpaper, let content, wallpaper.identity.wallpaperID == content.wallpaperID,
           wallpaper.documentSignature == content.documentSignature {
            self.content = content
            return
        }
        stop()
        self.content = content
        guard let content, let services else { return }
        do {
            let started = try SceneScriptWallpaper(content: content, services: services, screenID: screenID)
            started?.onHalt = { [weak self] error in self?.onHalt?(error) }
            wallpaper = started
        } catch {
            OWELog.error(.script, "\(content.wallpaperID): scripts are off: \(error)")
        }
    }

    /// Stops the scripts (their `destroy()` runs on the script thread) and forgets their state.
    func stop() {
        wallpaper?.tearDown()
        wallpaper = nil
        content = nil
        state = SceneScriptFrameState()
        lastScreenSize = nil
    }

    /// Builds the layer of an object a script created, through the loader. Off the main thread.
    var makeLayer: (([String: SceneJSON]) -> SceneMetalLayer?)? { content?.makeLayer }

    // MARK: - Frame

    /// The state the scripts' last finished frame left, and the structural changes since.
    func beginFrame() -> [SceneScriptRenderEvent] {
        guard let wallpaper else { return [] }
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let taken = wallpaper.take()
        if let latest = taken.state { state = latest }
        record(since: start)
        return taken.events
    }

    /// Adds render-thread CPU time since `start` to this frame's bridge cost (`bridgeMilliseconds`).
    func record(since start: UInt64, newFrame: Bool = true) {
        let milliseconds = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1_000_000
        if newFrame {
            if bridgeMilliseconds.count >= SceneScriptWallpaper.Timing.recentLimit { bridgeMilliseconds.removeFirst() }
            bridgeMilliseconds.append(milliseconds)
        } else if !bridgeMilliseconds.isEmpty {
            bridgeMilliseconds[bridgeMilliseconds.count - 1] += milliseconds
        }
    }

    /// Hands this frame's inputs to the scripts and starts their next frame. The first display size
    /// is the environment's; a later change is a `resizeScreen`.
    func submit(_ input: SceneScriptFrameInput) {
        guard let wallpaper else { return }
        let size = input.environment.screenResolution
        if let lastScreenSize, lastScreenSize != size { wallpaper.screenDidResize(width: size.x, height: size.y) }
        lastScreenSize = size
        wallpaper.submit(input)
    }

    /// `applyUserProperties` for changed user properties.
    func userPropertiesDidChange(_ names: Set<String>) {
        wallpaper?.userPropertiesDidChange(names)
    }

    var isRunning: Bool { wallpaper != nil }

    // MARK: - Reads

    /// What scripts left in object `id`, if they touched it.
    func object(_ id: String) -> SceneScriptObjectState? {
        guard !state.objects.isEmpty, let key = Int(id) else { return nil }
        return state.objects[key]
    }

    /// Whether object `id` is drawn: its own `visible` (a script's, else its base) and every
    /// parent's (WE hides a hidden object's children).
    func isVisible(_ id: String, base: Bool? = nil) -> Bool {
        var current: String? = id
        var visited = Set<String>()
        while let object = current, visited.insert(object).inserted {
            let own = self.object(object)?.flag(.visible) ?? (object == id ? base : nil) ?? baseVisibility[object] ?? true
            if !own { return false }
            current = parents[object]
        }
        return true
    }

    /// Records the base `visible` of an object scripts created.
    func setBaseVisibility(_ visible: Bool, for id: String) {
        baseVisibility[id] = visible
    }

    func baseVisible(_ id: String) -> Bool { baseVisibility[id] ?? true }

    /// A text layer's configuration with what scripts set: `text`, `pointsize` and alignments.
    func text(_ text: SceneMetalText, of id: String) -> (text: SceneMetalText, value: String, pointSize: Float?) {
        guard let object = object(id) else { return (text, text.value, nil) }
        let scripted = SceneMetalText(
            value: text.value, font: text.font, pointSize: text.pointSize,
            horizontalAlignment: object.strings[.horizontalalign] ?? text.horizontalAlignment,
            verticalAlignment: object.strings[.verticalalign] ?? text.verticalAlignment,
            padding: text.padding, maxWidth: text.maxWidth, maxRows: text.maxRows, useEllipsis: text.useEllipsis,
            anchor: text.anchor, blockAlign: text.blockAlign)
        let pointSize = object.scalar(.pointsize).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        return (scripted, object.strings[.text] ?? text.value, pointSize)
    }

    /// The effect graph's view of a layer's effects this frame: which are hidden (base `visible`
    /// or a script's) and the constants scripts set.
    func effects(_ plans: [SceneEffectPlan], of id: String) -> (hidden: Set<Int>, writes: [Int: [SceneScriptConstantWrite]], revision: Int) {
        let object = object(id)
        var hidden = Set<Int>()
        for (index, plan) in plans.enumerated() where !(object?.effectVisible[plan.effectIndex] ?? plan.visible) {
            hidden.insert(index)
        }
        return (hidden, object?.constants ?? [:], object?.effectRevision ?? 0)
    }

    // MARK: - Draw order

    /// Layers in draw order and, for each, the particle systems to draw before it (the
    /// `before` argument of the renderer's particle batches: every system whose authored order is
    /// below it). Without script changes to the order, the scene's own.
    /// `layers` are (id, authored order); `systems` are (object id, authored order).
    static func drawOrder(layers: [(id: String, order: Int)], systems: [(id: String?, order: Int)],
                          scriptOrder: [Int]?) -> (sequence: [Int], barriers: [Int]) {
        guard let scriptOrder else {
            let sequence = layers.indices.sorted { (layers[$0].order, $0) < (layers[$1].order, $1) }
            return (sequence, sequence.map { layers[$0].order })
        }
        var position: [String: Int] = [:]
        for (index, id) in scriptOrder.enumerated() { position[String(id)] = index }
        func place(_ id: String?, _ order: Int) -> Int { id.flatMap { position[$0] } ?? order }
        let sequence = layers.indices.sorted {
            (place(layers[$0].id, layers[$0].order), $0) < (place(layers[$1].id, layers[$1].order), $1)
        }
        let placedSystems = systems.map { (place($0.id, $0.order), $0.order) }.sorted { $0.0 < $1.0 }
        var barriers: [Int] = []
        var next = 0
        var barrier = Int.min
        for index in sequence {
            let at = place(layers[index].id, layers[index].order)
            while next < placedSystems.count, placedSystems[next].0 < at {
                barrier = max(barrier, placedSystems[next].1 + 1)
                next += 1
            }
            barriers.append(barrier)
        }
        return (sequence, barriers)
    }
}
