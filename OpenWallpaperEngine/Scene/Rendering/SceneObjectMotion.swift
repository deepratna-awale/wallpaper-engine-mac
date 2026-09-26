import simd

/// Where an object's own transform comes from each frame: its authored (or user-bound) origin,
/// scale and `angles.z`, what its timelines set (`SceneObjectAnimation`), and what scripts wrote
/// into the object table. Drawn layers carry one, and so does every other object (groups, particle
/// systems), so children follow their live parents whatever the parent is.
struct SceneObjectMotion {
    let name: String
    let origin: SIMD2<Float>
    let scale: SIMD2<Float>
    /// `angles.z`, in radians.
    let angle: Float
    /// User-bound origin, scale and angles, re-resolved per frame.
    var bindings = SceneLayerBindings()

    init(layer: SceneMetalLayer) {
        name = layer.name
        origin = layer.position
        scale = layer.scale
        angle = layer.rotation
        bindings = layer.bindings
    }

    init(object: WESceneObject, sceneSize: SIMD2<Float>, bindings: SceneLayerBindings) {
        let local = SceneLocalTransform(object: object, sceneSize: sceneSize)
        name = object.name ?? ""
        origin = local.origin
        scale = local.scale
        angle = local.angle
        self.bindings = bindings
    }

    /// The values animations start from this frame.
    func base(in context: SceneValueContext) -> SceneLayerBaseValues {
        let built = SceneLayerBaseValues(position: origin, scale: scale, rotation: angle)
        return bindings.isEmpty ? built : bindings.baseValues(built, in: context)
    }

    /// The object's own origin, scale and `angles.z` this frame: what scripts wrote (`script`),
    /// then its timelines (`animation`), then authored or user-bound. Scripts win over a timeline:
    /// WE runs the timeline first and applies the script's return after it (plan §1.9 P2).
    /// Without `scriptValues`: the object as the renderer alone would place it, which is what
    /// scripts read for fields they don't own.
    func local(animation: SceneObjectAnimation? = nil, script: SceneScriptObjectState? = nil,
               scriptValues: Bool = true) -> SceneLocalTransform {
        let base = base(in: LiveSceneValueContext())
        let owned = scriptValues ? script : nil
        let position = owned?.vector3(.origin).map(Self.xy) ?? animation?.origin.map(Self.xy) ?? base.position
        let scale = owned?.vector3(.scale).map(Self.xy) ?? animation?.scale.map(Self.xy) ?? base.scale
        let rotation = owned?.vector3(.angles)?.z ?? animation?.angles?.z ?? base.rotation
        return SceneLocalTransform(origin: position, scale: scale, angle: rotation)
    }

    private static func xy(_ value: SIMD3<Float>) -> SIMD2<Float> { SIMD2(value.x, value.y) }
}
