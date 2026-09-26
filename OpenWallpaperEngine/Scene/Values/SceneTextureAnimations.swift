import Foundation

/// A wallpaper instance's texture animations (docs/timeline-plan.md §2.7, §3.2): one shared
/// `SceneTextureAnimationClock` per animated texture, however many layers draw it, and each image
/// layer's `ITextureAnimation` override (`SceneTextureAnimationControl`).
///
/// A texture only moves when something draws it (`drawnFrame`), at most one step per engine frame.
/// Confined to the thread that owns the wallpaper's `SceneAnimationSet`.
final class SceneTextureAnimations {
    /// An `ITextureAnimation` call on a layer.
    enum Control: Equatable {
        case play, pause, stop, join
        case setFrame(Int32)
        case setRate(Float)
    }

    /// What scripts read of a layer's texture animation: its override and the shared clock.
    struct State: Equatable {
        var control: SceneTextureAnimationControl
        var sharedFrame: Int32
        var sharedTime: Float
        var frameCount: Int
        var duration: Float
    }

    private struct Layer {
        var texture: String
        var control = SceneTextureAnimationControl()
    }

    private var clocks: [String: SceneTextureAnimationClock] = [:]
    private var layers: [Int: Layer] = [:]

    /// Object `id` draws the animated texture `texture` (its path, the shared clock's key), whose
    /// TEXS frames last `frameTimes` seconds. The first user creates the texture's clock.
    func register(object id: Int, texture: String, frameTimes: [Float]) {
        if clocks[texture] == nil { clocks[texture] = SceneTextureAnimationClock(frameTimes: frameTimes) }
        layers[id] = Layer(texture: texture)
    }

    /// The layer is gone; its texture's clock goes with its last user.
    func removeObject(_ id: Int) {
        guard let removed = layers.removeValue(forKey: id) else { return }
        if !layers.values.contains(where: { $0.texture == removed.texture }) { clocks[removed.texture] = nil }
    }

    /// The shared clock of `texture`, for materials that draw it without a layer of their own.
    func clock(texture: String) -> SceneTextureAnimationClock? { clocks[texture] }

    var objectIDs: [Int] { Array(layers.keys) }

    /// The sprite frame object `id` draws this engine frame (`tick`): advances the texture's shared
    /// clock once per tick and the layer's override when a script controls it. `delta` is the
    /// engine frame time; a script's `rate` scales only the override.
    func drawnFrame(object id: Int, tick: UInt64, delta: Float) -> Int32? {
        guard var layer = layers[id], let shared = clocks[layer.texture] else { return nil }
        let frame = layer.control.drawnFrame(shared: shared, tick: tick, delta: delta)
        layers[id] = layer
        return frame
    }

    /// Applies a script call the way WE's wrapper does. False for an unknown layer.
    @discardableResult
    func perform(_ control: Control, object id: Int) -> Bool {
        guard var layer = layers[id], let shared = clocks[layer.texture] else { return false }
        switch control {
        case .play: layer.control.play()
        case .pause: layer.control.pause(shared: shared)
        case .stop: layer.control.stop()
        case .join: layer.control.join()
        case .setFrame(let frame): layer.control.setFrame(frame)
        case .setRate(let rate): layer.control.setRate(rate, shared: shared)
        }
        layers[id] = layer
        return true
    }

    /// Replaces a layer's override with what the script left (the JS side applies the same rules
    /// during the script frame; the host reads the dirty slot back afterwards).
    @discardableResult
    func restore(_ control: SceneTextureAnimationControl, object id: Int) -> Bool {
        guard layers[id] != nil else { return false }
        layers[id]?.control = control
        return true
    }

    func state(object id: Int) -> State? {
        guard let layer = layers[id], let shared = clocks[layer.texture] else { return nil }
        return State(control: layer.control, sharedFrame: shared.frame, sharedTime: shared.time,
                     frameCount: shared.frameCount, duration: shared.duration)
    }
}
