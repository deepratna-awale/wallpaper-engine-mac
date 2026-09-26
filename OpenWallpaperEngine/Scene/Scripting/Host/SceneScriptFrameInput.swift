import simd

/// What the renderer hands the scripts for one frame (docs/scenescript-plan.md §4.4, WP11): the
/// clock, the cursor and display, and every object as it was last drawn. The script thread writes
/// it into the object table before the frame, so `update(value)` and member reads see the live
/// values (§1.9 P2) and `getTransformMatrix`/cursor hit tests see the last world transforms.
struct SceneScriptFrameInput {
    /// Scene seconds since the last frame (speed applied).
    var deltaTime: Double = 0
    /// `engine` and `input`'s display and placement.
    var environment = SceneScriptEngineEnvironment.standard
    /// `input.cursorScreenPosition` (display pixels from the top-left) and `cursorLeftDown`.
    var input = SceneScriptInput()
    /// The scene point under the cursor as the unshaken camera sees it (scene units, y up).
    var cursorScenePosition = SIMD2<Float>(repeating: 0)
    /// How far camera shake moved the camera this frame: WE shakes the eye, so the cursor's world
    /// position moves with it.
    var shakeOffset = SIMD2<Float>(repeating: 0)
    /// Camera parallax, for an orthographic scene with parallax on (the cursor pass offsets quads).
    var parallax: SceneScriptCursorFrame.Parallax?
    /// Every object the renderer drew or moved, by scene.json id.
    var objects: [Int: SceneScriptObjectFeedback] = [:]
}

/// One object as the renderer last drew it, in the object table's units. A value is written into
/// the table only where scripts don't own the field (or where a timeline animates it: the
/// animation runs first and a script's return overrides it, §1.9 P2).
struct SceneScriptObjectFeedback {
    var origin: SIMD2<Float>
    var scale: SIMD2<Float>
    /// `angles.z`, radians.
    var angle: Float
    var alpha: Float?
    var color: SIMD3<Float>?
    /// The object's own `visible` before scripts (authored or user-bound).
    var visible: Bool
    /// The unscaled quad size (`ILayer.size`, read-only for scripts); nil for objects without one.
    var size: SIMD2<Float>?
    /// Parents included, without camera parallax or shake.
    var world: SceneAffineTransform
    /// Fields a timeline animates this frame.
    var animated = SceneScriptOwnedFields()

    /// The world transform as the table's column-major 4×4 matrix.
    var worldMatrix: [Float] {
        let linear = world.linear
        return [linear.columns.0.x, linear.columns.0.y, 0, 0,
                linear.columns.1.x, linear.columns.1.y, 0, 0,
                0, 0, 1, 0,
                world.translation.x, world.translation.y, 0, 1]
    }
}
