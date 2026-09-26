import simd

/// Where an object's own transform comes from each frame: its authored (or user-bound) origin,
/// scale and `angles.z`, the timeline animations that move them, and what scripts wrote into the
/// object table. Drawn layers carry one, and so does every other object (groups, particle
/// systems), so children follow their live parents whatever the parent is.
struct SceneObjectMotion {
    let name: String
    let origin: SIMD2<Float>
    let scale: SIMD2<Float>
    /// `angles.z`, in radians.
    let angle: Float
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
        originAnimation = object.originAnimation
        scaleAnimation = object.scaleAnimation
        anglesAnimation = object.anglesAnimation
        self.bindings = bindings
    }

    /// The values animations start from this frame.
    func base(in context: SceneValueContext) -> SceneLayerBaseValues {
        let built = SceneLayerBaseValues(position: origin, scale: scale, rotation: angle)
        return bindings.isEmpty ? built : bindings.baseValues(built, in: context)
    }

    /// Fields a timeline animates.
    var animatedFields: SceneScriptOwnedFields {
        var fields = SceneScriptOwnedFields()
        if originAnimation != nil { fields.insert(.origin) }
        if scaleAnimation != nil { fields.insert(.scale) }
        if anglesAnimation != nil { fields.insert(.angles) }
        return fields
    }

    /// The object's own origin, scale and `angles.z` at `time`: what scripts wrote (`script`),
    /// then the timeline (at a script-controlled animation's own time), then authored or
    /// user-bound. Scripts win over an animation: WE runs the animation first and applies the
    /// script's return after it (plan §1.9 P2).
    /// Without `scriptValues`, only the script-controlled animation times apply: the object as
    /// the renderer alone would place it, which is what scripts read for fields they don't own.
    func local(at time: Float, script: SceneScriptObjectState? = nil, scriptValues: Bool = true) -> SceneLocalTransform {
        let base = base(in: LiveSceneValueContext(time: Double(time)))
        func at(_ property: String) -> Float { script?.animationTimes[property].map(Float.init) ?? time }
        let owned = scriptValues ? script : nil
        let position = owned?.vector3(.origin).map(Self.xy) ?? Self.xy(SceneTimeline.vector3(
            originAnimation, at: at("origin"), fallback: SIMD3<Float>(base.position.x, base.position.y, 0)))
        let scale = owned?.vector3(.scale).map(Self.xy) ?? Self.xy(SceneTimeline.vector3(
            scaleAnimation, at: at("scale"), fallback: SIMD3<Float>(base.scale.x, base.scale.y, 1)))
        let rotation = owned?.vector3(.angles)?.z ?? SceneTimeline.vector3(
            anglesAnimation, at: at("angles"), fallback: SIMD3<Float>(0, 0, base.rotation)).z
        return SceneLocalTransform(origin: position, scale: scale, angle: rotation)
    }

    private static func xy(_ value: SIMD3<Float>) -> SIMD2<Float> { SIMD2(value.x, value.y) }
}
