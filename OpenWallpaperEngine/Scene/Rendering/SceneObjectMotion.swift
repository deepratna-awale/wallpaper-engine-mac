import simd

/// Where an object's own transform comes from each frame: its authored (or user-bound) origin,
/// scale and `angles.z`, and the scripts and timeline animations that move them. Drawn layers
/// carry one, and so does every other object (groups, particle systems), so children follow
/// their live parents whatever the parent is.
struct SceneObjectMotion {
    let name: String
    let origin: SIMD2<Float>
    let scale: SIMD2<Float>
    /// `angles.z`, in radians.
    let angle: Float
    let originScript: String?
    let scaleScript: String?
    let anglesScript: String?
    let originAnimation: WEVectorKeyframeAnimation?
    let scaleAnimation: WEVectorKeyframeAnimation?
    let anglesAnimation: WEVectorKeyframeAnimation?
    /// User-bound origin, scale and angles, re-resolved per frame.
    var bindings = SceneLayerBindings()

    init(layer: SceneMetalLayer) {
        name = layer.name
        origin = layer.position
        scale = layer.scale
        angle = layer.rotation
        originScript = layer.positionScript
        scaleScript = layer.scaleScript
        anglesScript = layer.rotationScript
        originAnimation = layer.positionAnimation
        scaleAnimation = layer.scaleAnimation
        anglesAnimation = layer.rotationAnimation
        bindings = layer.bindings
    }

    init(object: WESceneObject, sceneSize: SIMD2<Float>, bindings: SceneLayerBindings) {
        let local = SceneLocalTransform(object: object, sceneSize: sceneSize)
        name = object.name ?? ""
        origin = local.origin
        scale = local.scale
        angle = local.angle
        originScript = object.originScript
        scaleScript = object.scaleScript
        anglesScript = object.anglesScript
        originAnimation = object.originAnimation
        scaleAnimation = object.scaleAnimation
        anglesAnimation = object.anglesAnimation
        self.bindings = bindings
    }

    /// The values scripts and animations start from this frame.
    func base(in context: SceneValueContext) -> SceneLayerBaseValues {
        let built = SceneLayerBaseValues(position: origin, scale: scale, rotation: angle)
        return bindings.isEmpty ? built : bindings.baseValues(built, in: context)
    }

    /// The object's own origin, scale and `angles.z` at `time`: script, then script-set state
    /// (under `stateId`), then timeline, then authored (or user-bound).
    func local(at time: Float, stateId: String) -> SceneLocalTransform {
        let engine = AudioReactiveScriptEngine.shared
        let base = base(in: LiveSceneValueContext(time: Double(time), scriptTime: Double(time), layerId: stateId))
        // origin is a Vec3 in Wallpaper Engine; scripts read and write value.z, so evaluating
        // it as a Vec2 hands them an object with no z and silently corrupts the result.
        let position = originScript.flatMap { script -> SIMD2<Float>? in
            engine.evaluateVector3(script, fallback: SIMD3<Float>(base.position.x, base.position.y, 0),
                                   layerId: stateId, time: Double(time)).map { SIMD2<Float>($0.x, $0.y) }
        } ?? engine.layerVector2(stateId, property: "origin", fallback: Self.xy(SceneTimeline.vector3(
            originAnimation, at: time, fallback: SIMD3<Float>(base.position.x, base.position.y, 0))))
        let scale = scaleScript.flatMap { script -> SIMD2<Float>? in
            engine.evaluateVector3(script, fallback: SIMD3<Float>(base.scale.x, base.scale.y, 1),
                                   layerId: stateId, time: Double(time)).map { SIMD2<Float>($0.x, $0.y) }
        } ?? engine.layerVector2(stateId, property: "scale", fallback: Self.xy(SceneTimeline.vector3(
            scaleAnimation, at: time, fallback: SIMD3<Float>(base.scale.x, base.scale.y, 1))))
        // `angles` is a Vec3 in Wallpaper Engine; scripts mutate value.x/y/z, so it has to be
        // evaluated as a vector even though only the Z rotation is used here.
        let rotation = anglesScript.flatMap {
            engine.evaluateVector3($0, fallback: SIMD3<Float>(0, 0, base.rotation), layerId: stateId, time: Double(time))?.z
        } ?? engine.layerValue(stateId, property: "angles.z", fallback: SceneTimeline.vector3(
            anglesAnimation, at: time, fallback: SIMD3<Float>(0, 0, base.rotation)).z)
        return SceneLocalTransform(origin: position, scale: scale, angle: rotation)
    }

    private static func xy(_ value: SIMD3<Float>) -> SIMD2<Float> { SIMD2(value.x, value.y) }
}
