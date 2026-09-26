/// What a scene holds for WE's 3D runtime (docs/models-plan.md § Seams): the projection and
/// camera settings, the model objects, the camera layers and the scene camera paths, and the
/// draw-order mode. Built by `SceneSpatialContentBuilder`; nothing draws from it yet except
/// through `SceneCameraRigs`.
struct SceneSpatialContent: Equatable {
    var camera = SceneCameraSettings()
    /// The `camera` block's eye, centre and up, with WE's defaults for missing vectors.
    var staticEye = SceneCameraDefaults.eye
    var staticCenter = SceneCameraDefaults.center
    var staticUp = SceneCameraDefaults.up
    /// Every path of every `camera.paths` file, in order (they play in sequence and loop).
    var cameraPaths: [WESceneCameraPath] = []
    var cameraLayers: [SceneCameraLayerObject] = []
    var models: [SceneModelObject] = []
    var drawOrder = SceneDrawOrderMode.sceneOrder
}
