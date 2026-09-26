/// A model object as the content was built (docs/models-plan.md §2.6). Today it carries the
/// authored fields only and nothing draws it; M5's `SceneModelBuilder` adds the parsed `.mdl`,
/// its materials and bounds.
struct SceneModelObject: Equatable {
    /// The scene object's id (the key of `SceneMetalContent.transforms` and `visibility`).
    var id: String
    var name: String
    /// Its index in scene.json.
    var order: Int
    var authored: WESceneModel
    /// The object's `animationlayers`.
    var animationLayers: [WEAnimationLayer] = []
    /// `sortorder`, `castshadow` (true for models unless authored), `reflected`, `depthtest`.
    var renderValues: [SceneObjectRenderField: SceneRawValue] = [:]
}
