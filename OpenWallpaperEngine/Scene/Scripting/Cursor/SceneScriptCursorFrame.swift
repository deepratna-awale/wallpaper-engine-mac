import simd

/// What the renderer hands the cursor pass once per frame (docs/scenescript-plan.md §4.8, WP11):
/// where the cursor is, whether the left button is down, and the hit-testable layers as last drawn.
struct SceneScriptCursorFrame {
    /// Camera parallax as the renderer ran it this frame. Only an orthographic scene with parallax
    /// on offsets the quads (flags 0x108 at 0x140189f17), so it is nil otherwise.
    struct Parallax {
        var state: SceneCameraParallax
        /// `cameraparallaxamount`.
        var amount: Float
    }

    /// The scene point under the cursor as WE's camera sees it, the `worldPosition` of every event:
    /// scene units, y up. WE moves the camera eye for camera shake, so this is the unshaken scene
    /// point plus the shake offset. WE uses only x and y; z is reported as given.
    var cursorWorldPosition: SIMD3<Float>
    /// The left button, for clicks the wallpaper itself receives (plan §4.8).
    var leftButtonDown: Bool
    var parallax: Parallax?
    /// Every hit-testable object in draw order, bottom first. The pass walks it from the top.
    var layers: [SceneScriptCursorLayer]

    init(cursorWorldPosition: SIMD3<Float>, leftButtonDown: Bool, parallax: Parallax? = nil,
         layers: [SceneScriptCursorLayer]) {
        self.cursorWorldPosition = cursorWorldPosition
        self.leftButtonDown = leftButtonDown
        self.parallax = parallax
        self.layers = layers
    }

    /// How far WE's hit test moves `layer`'s quad for camera parallax (0x14018a0b3):
    /// `amount · (origin − position) · parallaxDepth` of the object itself.
    func parallaxOffset(of layer: SceneScriptCursorLayer) -> SIMD2<Float> {
        guard let parallax else { return .zero }
        return parallax.state.offset(rootOrigin: layer.origin, rootDepth: layer.parallaxDepth, amount: parallax.amount)
    }
}
