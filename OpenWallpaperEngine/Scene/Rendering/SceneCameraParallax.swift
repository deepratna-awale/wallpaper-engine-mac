import simd

/// Wallpaper Engine's camera parallax (`general.cameraparallax*`), as `wallpaper64.exe` runs it.
///
/// Every frame with parallax on (the scene update, 0x140189b0f…0x140189cc6):
/// 1. The cursor, normalised with y up, is clamped to 0…1.
/// 2. `target = eye.xy + size · (cursor · influence + 0.5 · (1 − influence))`. `size` is the
///    orthographic projection and `influence` is `cameraparallaxmouseinfluence`. `eye` is the
///    camera eye after camera shake: an orthographic scene without camera paths has its authored
///    eye reset to 0 at load (0x14018866b), so only the shake is left in it.
/// 3. With `cameraparallaxdelay` > 0 the position eases toward the target:
///    `position += (target − position) · min(1, (1 − delay / 3) · 10 · dt)`. Otherwise it is the target.
/// 4. `g_ParallaxPosition = clamp(position / size, 0, 1)`.
///
/// At load the position is the scene centre and `g_ParallaxPosition` is (0.5, 0.5)
/// (0x1401886ea…0x140188728); with parallax off neither changes.
///
/// In an orthographic scene the renderer then draws every object translated by
/// `cameraparallaxamount · (root.origin.xy − position) · root.parallaxDepth.xy`
/// (0x14018b062…0x14018b14e). `root` is the object's topmost ancestor, so a child moves with
/// the object it hangs from. The mouse hit test uses the same offset (0x14018a0b3).
struct SceneCameraParallax: Equatable {
    /// Where the camera's parallax looks, in scene units (y up).
    private(set) var position: SIMD2<Float>

    init(sceneSize: SIMD2<Float>) {
        position = sceneSize * 0.5
    }

    /// Advances one frame. `cursor` is normalised with y up; `eye` is the camera eye's xy after shake.
    mutating func update(cursor: SIMD2<Float>, eye: SIMD2<Float>, sceneSize: SIMD2<Float>,
                         influence: Float, delay: Float, deltaTime: Float) {
        let cursor = simd_clamp(cursor, SIMD2<Float>(repeating: 0), SIMD2<Float>(repeating: 1))
        let target = eye + sceneSize * (cursor * influence + 0.5 * (1 - influence))
        guard delay > 0 else {
            position = target
            return
        }
        let rate = min(1, (1 - delay / 3) * 10 * deltaTime)
        position += (target - position) * rate
    }

    /// `g_ParallaxPosition`.
    func shaderPosition(sceneSize: SIMD2<Float>) -> SIMD2<Float> {
        simd_clamp(position / sceneSize, SIMD2<Float>(repeating: 0), SIMD2<Float>(repeating: 1))
    }

    /// How far an object is drawn from where its transform puts it. `origin` and `depth` are
    /// its root object's `origin` and `parallaxDepth`.
    func offset(rootOrigin: SIMD2<Float>, rootDepth: SIMD2<Float>, amount: Float) -> SIMD2<Float> {
        amount * (rootOrigin - position) * rootDepth
    }
}
