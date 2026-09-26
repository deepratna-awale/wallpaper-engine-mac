import Foundation

/// Builds a scene's `SceneSpatialContent` (docs/models-plan.md § Seams): the camera settings,
/// the `camera` block, its path files, every camera layer with its path file, and every model
/// object. Objects must already carry their ids (`SceneObjectIdentity.assigningFallbackIDs`).
struct SceneSpatialContentBuilder {
    /// Reads a file of the wallpaper (its folder, its `.pkg` or WE's assets); nil when missing.
    var readFile: (String) -> Data?
    /// For log lines.
    var wallpaperName: String

    func build(_ scene: WEScene, context: SceneValueContext) -> SceneSpatialContent {
        var content = SceneSpatialContent()
        content.camera = SceneCameraSettings(scene.general, in: context)
        content.drawOrder = SceneDrawOrderMode(content.camera)
        if let eye = scene.camera.eye { content.staticEye = Self.vector(eye) }
        if let center = scene.camera.center { content.staticCenter = Self.vector(center) }
        if let up = scene.camera.up { content.staticUp = Self.vector(up) }
        for file in scene.camera.paths ?? [] {
            guard let data = read(file, what: "camera path") else { continue }
            do {
                content.cameraPaths += try WESceneCameraPathFile(data: data).paths
            } catch {
                OWELog.error(.scene, "\(wallpaperName): camera path \(file) can't be read: \(error)")
            }
        }
        for (index, object) in scene.objects.enumerated() {
            let id = String(object.id ?? -1)
            let name = object.name ?? "#\(index)"
            if let model = object.model {
                content.models.append(SceneModelObject(id: id, name: name, order: index, authored: model,
                                                       animationLayers: object.animationLayers,
                                                       renderValues: object.renderValues))
            } else if let layer = object.cameraLayer {
                content.cameraLayers.append(SceneCameraLayerObject(id: id, name: name, order: index, authored: layer,
                                                                   pathFile: layer.path.flatMap(cameraLayerPaths)))
            }
        }
        if !content.models.isEmpty {
            // Area 6 (docs/models-plan.md): decoded, but nothing draws a model yet.
            OWELog.info(.scene, "\(wallpaperName): \(content.models.count) model objects aren't drawn yet")
        }
        return content
    }

    private func cameraLayerPaths(_ file: String) -> WECameraLayerPathFile? {
        guard let data = read(file, what: "camera layer path") else { return nil }
        do {
            return try WECameraLayerPathFile(data: data)
        } catch {
            OWELog.error(.scene, "\(wallpaperName): camera layer path \(file) can't be read: \(error)")
            return nil
        }
    }

    private func read(_ file: String, what: String) -> Data? {
        guard let data = readFile(file) else {
            OWELog.error(.scene, "\(wallpaperName): \(what) \(file) is missing")
            return nil
        }
        return data
    }

    private static func vector(_ text: String) -> SIMD3<Float> {
        let (x, y, z) = text.parseVector3()
        return SIMD3(Float(x), Float(y), Float(z))
    }
}
