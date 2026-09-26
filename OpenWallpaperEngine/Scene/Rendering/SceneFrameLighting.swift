import simd

/// A light object as the content was built: its scene object's id (the light's transform, parent
/// and visibility are the object's), its fields as authored (for values that change live) and
/// resolved against the user properties.
struct SceneLightObject {
    var id: String
    var authored: WESceneLight
    var light: SceneLight
}

/// The scene's lighting as the content was built: `general`'s colours and budget, and every light
/// object in scene order (docs/lighting-plan.md §1).
struct SceneLightingContent {
    var settings = SceneLightingSettings()
    var lights: [SceneLightObject] = []
}

/// What the renderer hands the lighting each frame, after scripts and timelines ran.
struct SceneFrameLightingInput {
    /// An object's world transform this frame (its parents', scripts' and timelines' included);
    /// nil for an id the scene doesn't have.
    var world: (String) -> SceneAffineTransform?
    /// Whether an object is shown this frame (its own `visible`, scripts' included).
    var isVisible: (String) -> Bool
    /// A `general` colour scripts set this frame (`thisScene.ambientcolor`, `skylightcolor`); nil
    /// when no script owns it.
    var sceneColor: (SceneScriptSceneField) -> SIMD3<Float>?
    var eyePosition: SIMD3<Float>
    var viewForward: SIMD3<Float>
}

/// One frame's lighting: the values behind `g_LightAmbientColor`, `g_LightSkylightColor`, the
/// `LightingV1` arrays (`g_LPoint_*`, `g_LSpot_*`, `g_LTube_*`, `g_LDirectional_*`,
/// `g_LFeature_*`) and the legacy `g_Lights*` (docs/lighting-plan.md §2.2). The renderer builds it
/// once per frame (`frame(_:input:)`) and carries it on `BuiltinFrameContext.lighting`.
///
/// Nothing reads it yet: the built-in uniforms still use `BuiltinFrameContext.ambient`/`skylight`,
/// and `arrays` stays empty until the light packer fills it.
struct SceneFrameLighting: Equatable {
    var ambient = SceneGeneralDefaults.ambientColor
    var skylight = SceneGeneralDefaults.skylightColor
    /// Packed uniform values by uniform name, flattened as `BuiltinUniforms` returns them.
    var arrays: [String: [Float]] = [:]

    static func frame(_ content: SceneLightingContent, input: SceneFrameLightingInput) -> SceneFrameLighting {
        SceneFrameLighting(ambient: input.sceneColor(.ambientcolor) ?? content.settings.ambient,
                           skylight: input.sceneColor(.skylightcolor) ?? content.settings.skylight)
    }
}
