//
//  SceneWallpaperViewModel.swift
//  Open Wallpaper Engine
//
//  Loads and renders Wallpaper Engine scene wallpapers using SpriteKit.
//  Follows the same ViewModel pattern as VideoWallpaperViewModel.
//

import SpriteKit
import SwiftUI
import CoreText

class SceneWallpaperViewModel: ObservableObject {
    static func log(_ msg: String) {
        let line = "[SceneVM] \(msg)"
        NSLog("%@", line)
    }

    var currentWallpaper: WEWallpaper {
        willSet {
            loadScene(from: newValue)
        }
    }

    private(set) var metalRevision = 0

    private var pkgParser: PKGParser?
    private var loadedScene: WEScene?
    private var loadedWallpaperDirectory: URL?

    init(wallpaper: WEWallpaper) {
        self.currentWallpaper = wallpaper
        Self.log("init: wallpaper=\(wallpaper.project.title) dir=\(wallpaper.wallpaperDirectory.path)")
        loadScene(from: wallpaper)
    }

    deinit {
    }

    // MARK: - Scene Loading

    func loadScene(from wallpaper: WEWallpaper) {
        let dir = wallpaper.wallpaperDirectory
        let sceneFile = wallpaper.project.file  // e.g. "scene.json" or "gifscene.json"

        // Derive PKG name from scene file: "scene.json" → "scene.pkg", "gifscene.json" → "gifscene.pkg"
        let pkgName = (sceneFile as NSString).deletingPathExtension + ".pkg"
        let pkgURL = dir.appending(path: pkgName)
        let looseSceneURL = dir.appending(path: sceneFile)

        var scene: WEScene?

        if FileManager.default.fileExists(atPath: pkgURL.path(percentEncoded: false)) {
            do {
                let parser = try PKGParser(url: pkgURL)
                self.pkgParser = parser
                scene = try parser.extractJSON(named: sceneFile, as: WEScene.self)
            } catch {
                Self.log("Failed to parse PKG: \(error)")
            }
        } else if FileManager.default.fileExists(atPath: looseSceneURL.path(percentEncoded: false)) {
            // Loose files (no .pkg)
            self.pkgParser = nil
            do {
                let data = try Data(contentsOf: looseSceneURL)
                scene = try JSONDecoder().decode(WEScene.self, from: data)
            } catch {
                Self.log("Failed to parse loose \(sceneFile): \(error)")
            }
        }

        guard let scene = scene else {
            print("[SceneVM] No scene data found")
            NSLog("[SceneVM] No scene data found")
            return
        }

        prepareSceneUserPropertyDefaults(for: wallpaper, scene: scene)
        Self.log("Scene loaded: \(scene.objects.count) objects from \(sceneFile)")
        loadedScene = scene
        loadedWallpaperDirectory = dir
        metalRevision &+= 1
    }

    private func prepareSceneUserPropertyDefaults(for wallpaper: WEWallpaper, scene: WEScene) {
        guard wallpaper.project.type.caseInsensitiveCompare("scene") == .orderedSame,
              let data = try? Data(contentsOf: wallpaper.wallpaperDirectory.appending(path: "project.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let general = root["general"] as? [String: Any],
              let properties = general["properties"] as? [String: [String: Any]] else {
            return
        }
        let key = "SceneUserProperties.\(wallpaper.wallpaperDirectory.path)"
        let explicitKey = "SceneUserPropertiesExplicit.\(wallpaper.wallpaperDirectory.path)"
        let defaults = UserDefaults.standard
        var values = defaults.bool(forKey: explicitKey)
            ? defaults.dictionary(forKey: key) as? [String: String] ?? [:]
            : [:]
        for (name, property) in properties where values[name] == nil {
            if let value = property["value"] {
                values[name] = sceneUserPropertyString(value)
            } else if property["type"] as? String == "combo",
                      let option = (property["options"] as? [[String: Any]])?.first?["value"] {
                values[name] = sceneUserPropertyString(option)
            }
        }
        let conditionalImages = scene.objects.filter { $0.image != nil && $0.visibleUserProperty != nil }
        let hasSelectedVariant = conditionalImages.contains { object in
            guard let property = object.visibleUserProperty, let selectedValue = values[property] else { return false }
            if let condition = object.visibleCondition {
                return normalizeVariant(condition) == normalizeVariant(selectedValue)
            }
            return selectedValue.caseInsensitiveCompare("true") == .orderedSame || selectedValue == "1"
        }
        if !conditionalImages.isEmpty, !hasSelectedVariant,
           let fallback = conditionalImages.first(where: { $0.visible == true }) ?? conditionalImages.first,
           let property = fallback.visibleUserProperty {
            values[property] = fallback.visibleCondition ?? "true"
        }
        defaults.set(values, forKey: key)
        AudioReactiveScriptEngine.shared.setUserProperties(values)
    }

    // MARK: - SpriteKit Scene Building

    private func buildSKScene(from scene: WEScene, wallpaperDir: URL) -> SKScene {
        let projection = scene.general.orthogonalprojection ?? WEOrthogonalProjection(width: 1920, height: 1080)
        let skScene = SKScene(size: CGSize(width: projection.width, height: projection.height))
        skScene.scaleMode = .aspectFill
        skScene.backgroundColor = .black

        // Background color from clearcolor
        if let colorStr = scene.general.clearcolor {
            let c = colorStr.parseColor()
            skScene.backgroundColor = NSColor(red: c.r, green: c.g, blue: c.b, alpha: 1.0)
        }

        // Preserve the source object order so foreground layers render above backgrounds.
        var hasImage = false
        for (index, obj) in scene.objects.enumerated() {
            guard isObjectVisible(obj), obj.image != nil else { continue }
            // Skip additive/overlay layers that look like effects
            if let node = buildImageNode(obj, wallpaperDir: wallpaperDir) {
                if node.blendMode == .add { continue }
                node.zPosition = CGFloat(index)
                skScene.addChild(node)
                hasImage = true
            }
        }

        // Fallback: use preview image
        if !hasImage {
            let previewImage = loadPreviewImage(wallpaperDir: wallpaperDir)
            if let img = previewImage {
                let node = SKSpriteNode(texture: SKTexture(image: img))
                node.size = skScene.size
                node.position = CGPoint(x: skScene.size.width / 2, y: skScene.size.height / 2)
                skScene.addChild(node)
            }
        }

        return skScene
    }

    private func loadPreviewImage(wallpaperDir: URL) -> NSImage? {
        for name in ["preview.jpg", "preview.png", "preview.gif"] {
            let url = wallpaperDir.appending(path: name)
            if let image = NSImage(contentsOf: url) { return image }
        }
        return nil
    }

    func metalContent() -> SceneMetalContent? {
        guard let scene = loadedScene, let wallpaperDir = loadedWallpaperDirectory else { return nil }
        let sceneSize = metalSceneSize(for: scene)
        let visibility = resolvedVisibility(for: scene)
        var objectsByID: [Int: WESceneObject] = [:]
        for (index, object) in scene.objects.enumerated() {
            objectsByID[object.id ?? index] = object
        }
        let layers: [SceneMetalLayer] = scene.objects.compactMap { object in
            guard visibility[String(object.id ?? -1)] ?? false else { return nil }
            if object.textValue != nil,
               AudioReactiveScriptEngine.shared.userPropertyString("_owe_text_\(object.id ?? -1)_enabled") == "false" {
                return nil
            }
            return buildMetalLayer(object, wallpaperDir: wallpaperDir, sceneSize: sceneSize, objectsByID: objectsByID)
                ?? buildMetalTextLayer(object, sceneSize: sceneSize, objectsByID: objectsByID)
        }
        let particleSystems: [SceneMetalParticleSystem] = scene.objects.compactMap { object in
            guard visibility[String(object.id ?? -1)] ?? false else { return nil }
            return buildMetalParticleSystem(object, wallpaperDir: wallpaperDir, objectsByID: objectsByID)
        }
        if !layers.isEmpty || !particleSystems.isEmpty {
            let toggleableEffects = ["shake", "waterwaves", "nitro", "vhs", "pulse", "iris", "volumetricfog", "parallax"]
            let enabledEffects = toggleableEffects.filter {
                AudioReactiveScriptEngine.shared.userPropertyString("_owe_effect_enabled_\($0)") == "true"
            }
            return SceneMetalContent(size: sceneSize, layers: layers, particleSystems: particleSystems,
                                     effects: Set((scene.effects ?? []).map { $0.lowercased() }).union(enabledEffects))
        }
        guard let preview = loadPreviewImage(wallpaperDir: wallpaperDir) else { return nil }
        return SceneMetalContent(size: sceneSize, layers: [SceneMetalLayer(id: "preview", name: "preview", source: .image(preview),
            position: sceneSize / 2, size: sceneSize, scale: SIMD2<Float>(repeating: 1), scaleScript: nil, scaleAnimation: nil,
            opacity: 1, opacityScript: nil, opacityAnimation: nil,
            brightness: 1, brightnessScript: nil, color: SIMD4<Float>(repeating: 1), colorScript: nil,
            text: nil,
            parallaxDepth: .zero, perspective: false,
            positionScript: nil, positionAnimation: nil, sizeScript: nil, sizeAnimation: nil,
            rotation: 0, rotationScript: nil, rotationAnimation: nil,
            effects: SceneMaterialEffects(brightness: 1, contrast: 1, saturation: 1, bloom: 0, blur: 0,
                                          exposure: 0, gamma: 1, hue: 0, bloomThreshold: 0.7,
                                          transformAngle: 0, transformOffset: .zero, transformScale: SIMD2<Float>(repeating: 1), scripts: [:]),
            sceneEffects: [])], particleSystems: [], effects: [])
    }

    private func metalSceneSize(for scene: WEScene) -> SIMD2<Float> {
        if let projection = scene.general.orthogonalprojection {
            return SIMD2<Float>(Float(projection.width), Float(projection.height))
        }
        let imageBounds = scene.objects.compactMap { object -> SIMD2<Float>? in
            guard let origin = object.origin?.parseVector3(), let size = object.size?.parseVector2() else { return nil }
            return SIMD2<Float>(Float(origin.0 + size.0 / 2), Float(origin.1 + size.1 / 2))
        }
        guard let widest = imageBounds.map(\.x).max(), let tallest = imageBounds.map(\.y).max(),
              widest > 0, tallest > 0 else { return SIMD2<Float>(1920, 1080) }
        return SIMD2<Float>(widest, tallest)
    }

    /// Sums every ancestor's origin (not including the object itself), so parented objects
    /// (e.g. an effect attached to another layer) can be positioned relative to their parent.
    private func ancestorOrigin(for object: WESceneObject, sceneSize: SIMD2<Float>,
                                objectsByID: [Int: WESceneObject]) -> SIMD2<Float> {
        var total = SIMD2<Float>.zero
        var visited = Set<Int>()
        var parentID = object.parent
        while let id = parentID, visited.insert(id).inserted, let parentObject = objectsByID[id] {
            if let origin = parentObject.origin {
                let value = origin.parseVector3()
                total += SIMD2<Float>(Float(value.0), Float(value.1))
            } else if parentObject.parent == nil {
                // A root object without an explicit origin is anchored at the canvas center.
                total += sceneSize / 2
            }
            parentID = parentObject.parent
        }
        return total
    }

    /// An object's own origin (or canvas center if it's a root object without one) plus its ancestor chain.
    private func effectiveOrigin(for object: WESceneObject, sceneSize: SIMD2<Float>,
                                 objectsByID: [Int: WESceneObject]) -> SIMD2<Float> {
        let ownOrigin: SIMD2<Float>
        if let origin = object.origin {
            let value = origin.parseVector3()
            ownOrigin = SIMD2<Float>(Float(value.0), Float(value.1))
        } else if object.parent == nil {
            ownOrigin = sceneSize / 2
        } else {
            ownOrigin = .zero
        }
        return ownOrigin + ancestorOrigin(for: object, sceneSize: sceneSize, objectsByID: objectsByID)
    }

    private func buildMetalLayer(_ object: WESceneObject, wallpaperDir: URL, sceneSize: SIMD2<Float>,
                                 objectsByID: [Int: WESceneObject]) -> SceneMetalLayer? {
        guard let imagePath = object.image,
              let model: WEModel = loadJSON(path: imagePath, wallpaperDir: wallpaperDir),
              model.puppet == nil, // Puppet Warp rigs need mesh-based part assembly we don't support; skip rather than render the raw atlas.
              let materialPath = model.material,
              let material: WEMaterial = loadJSON(path: materialPath, wallpaperDir: wallpaperDir),
              let textureName = material.passes?.first?.textures?.first,
              let source = loadMetalTexture(named: textureName, materialDir: materialPath, wallpaperDir: wallpaperDir) else {
            return nil
        }
        let size: SIMD2<Float>
        if let sizeString = object.size {
            let value = sizeString.parseVector2()
            size = SIMD2<Float>(Float(value.0), Float(value.1))
        } else {
            switch source {
            case let .image(image): size = SIMD2<Float>(Float(image.size.width), Float(image.size.height))
            case let .dxt(texture): size = SIMD2<Float>(Float(texture.width), Float(texture.height))
            case let .animated(animation):
                guard let image = animation.images.first else { return nil }
                size = SIMD2<Float>(Float(image.size.width), Float(image.size.height))
            }
        }
        let position: SIMD2<Float> = effectiveOrigin(for: object, sceneSize: sceneSize, objectsByID: objectsByID)
        let rotation = Float(object.angles?.parseVector3().2 ?? 0)
        let staticScale = object.scale?.parseVector3() ?? (1, 1, 1)
        let objectColor = object.color?.parseVector3() ?? (1, 1, 1)
        let parallaxValue = object.parallaxDepth?.parseVector3() ?? (0, 0, 0)
        let effects = materialEffects(material.passes?.first)
        var sceneEffects = buildSceneEffects(object.effects ?? [], wallpaperDir: wallpaperDir)
        if object.name?.localizedCaseInsensitiveContains("cloud") == true {
            sceneEffects.append(SceneMetalEffect(name: "volumetricfog", constants: [:], mask: nil, scripts: [:]))
        }
        return SceneMetalLayer(id: String(object.id ?? -1), name: object.name ?? String(object.id ?? -1), source: source, position: position, size: size,
                       scale: SIMD2<Float>(Float(staticScale.0), Float(staticScale.1)),
                       scaleScript: object.scaleScript, scaleAnimation: object.scaleAnimation,
                       opacity: Float(object.alpha ?? 1), opacityScript: object.alphaScript,
                       opacityAnimation: object.alphaAnimation,
                       brightness: Float(object.brightness ?? 1), brightnessScript: object.brightnessScript,
                       color: SIMD4<Float>(Float(objectColor.0), Float(objectColor.1), Float(objectColor.2), 1), colorScript: object.colorScript,
                       text: nil,
                       parallaxDepth: SIMD3<Float>(Float(parallaxValue.0), Float(parallaxValue.1), Float(parallaxValue.2)),
                       perspective: object.perspective ?? false,
                       positionScript: object.originScript, positionAnimation: object.originAnimation,
                       sizeScript: object.sizeScript, sizeAnimation: nil,
                               rotation: rotation, rotationScript: object.anglesScript,
                               rotationAnimation: object.anglesAnimation, effects: effects, sceneEffects: sceneEffects)
    }

    private func buildMetalTextLayer(_ object: WESceneObject, sceneSize: SIMD2<Float>,
                                     objectsByID: [Int: WESceneObject]) -> SceneMetalLayer? {
        guard let text = object.textValue, let sizeString = object.size else { return nil }
        let sizeValue = sizeString.parseVector2()
        let position = effectiveOrigin(for: object, sceneSize: sceneSize, objectsByID: objectsByID)
        let textConfig = SceneMetalText(value: text, script: object.textScript, font: registerFont(object.font),
                                         pointSize: CGFloat(object.pointsize ?? 24),
                                         horizontalAlignment: object.horizontalalign,
                                         verticalAlignment: object.verticalalign)
        return SceneMetalLayer(id: String(object.id ?? -1), name: object.name ?? String(object.id ?? -1),
                               source: .image(renderText(textConfig, size: CGSize(width: sizeValue.0, height: sizeValue.1))),
                               position: position, size: SIMD2<Float>(Float(sizeValue.0), Float(sizeValue.1)),
                               scale: SIMD2<Float>(repeating: 1), scaleScript: object.scaleScript, scaleAnimation: object.scaleAnimation,
                               opacity: Float(object.alpha ?? 1), opacityScript: object.alphaScript, opacityAnimation: object.alphaAnimation,
                               brightness: 1, brightnessScript: nil, color: SIMD4<Float>(repeating: 1), colorScript: nil,
                               text: textConfig, parallaxDepth: .zero, perspective: false,
                               positionScript: object.originScript, positionAnimation: object.originAnimation,
                               sizeScript: object.sizeScript, sizeAnimation: object.sizeAnimation,
                               rotation: Float(object.angles?.parseVector3().2 ?? 0), rotationScript: object.anglesScript,
                               rotationAnimation: object.anglesAnimation,
                               effects: SceneMaterialEffects(brightness: 1, contrast: 1, saturation: 1, bloom: 0, blur: 0,
                                                             exposure: 0, gamma: 1, hue: 0, bloomThreshold: 0.7,
                                                             transformAngle: 0, transformOffset: .zero, transformScale: SIMD2<Float>(repeating: 1), scripts: [:]),
                               sceneEffects: [])
    }

    private func renderText(_ text: SceneMetalText, size: CGSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        let font = NSFont(name: text.font ?? "System", size: text.pointSize) ?? NSFont.systemFont(ofSize: text.pointSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = text.horizontalAlignment == "left" ? .left : text.horizontalAlignment == "right" ? .right : .center
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white, .paragraphStyle: paragraph]
        let attributed = NSAttributedString(string: text.value, attributes: attributes)
        let textSize = attributed.size()
        let y: CGFloat
        if text.verticalAlignment == "top" {
            y = size.height - textSize.height
        } else if text.verticalAlignment == "bottom" {
            y = 0
        } else {
            y = (size.height - textSize.height) / 2
        }
        attributed.draw(in: NSRect(x: 0, y: max(0, y), width: size.width, height: textSize.height))
        image.unlockFocus()
        return image
    }

    private func registerFont(_ path: String?) -> String? {
        guard let path,
              let data = pkgParser?.extractFile(named: path) else { return path }
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor],
              let descriptor = descriptors.first,
              let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String else {
            return path
        }
        if let provider = CGDataProvider(data: data as CFData),
           let font = CGFont(provider) {
            var error: Unmanaged<CFError>?
            CTFontManagerRegisterGraphicsFont(font, &error)
        }
        return name
    }

    private func buildSceneEffects(_ effects: [WEObjectEffect], wallpaperDir: URL) -> [SceneMetalEffect] {
        effects.compactMap { effect in
            guard isEffectVisible(effect),
                  let pass = effect.passes?.first else { return nil }
            let name = ((effect.file as NSString).deletingLastPathComponent as NSString).lastPathComponent.lowercased()
            var constants: [String: [Float]] = [:]
            var scripts: [String: String] = [:]
            for (key, value) in pass.constantshadervalues ?? [:] {
                if let script = value.script {
                    scripts[key.lowercased()] = script
                }
                if let number = value.number {
                    constants[key.lowercased()] = [Float(number)]
                } else if let string = value.string,
                          !string.split(separator: " ").isEmpty {
                    constants[key.lowercased()] = string.split(separator: " ").compactMap { Float($0) }
                }
            }
            let maskName = pass.textures?.compactMap { $0 }.first
            let mask = maskName.flatMap {
                loadMetalTexture(named: $0, materialDir: effect.file, wallpaperDir: wallpaperDir)
            }
            return SceneMetalEffect(name: name, constants: constants, mask: mask, scripts: scripts)
        }
    }

    private func isObjectVisible(_ object: WESceneObject) -> Bool {
        if let property = object.visibleUserProperty {
            guard let selectedValue = AudioReactiveScriptEngine.shared.userPropertyString(property) else { return false }
            if let condition = object.visibleCondition {
                return normalizeVariant(condition) == normalizeVariant(selectedValue)
            }
            return selectedValue.caseInsensitiveCompare("true") == .orderedSame || selectedValue == "1"
        }
        return object.visible != false
    }

    private func resolvedVisibility(for scene: WEScene) -> [String: Bool] {
        var visibility: [String: Bool] = [:]
        var objectsByID: [Int: WESceneObject] = [:]
        for (index, object) in scene.objects.enumerated() {
            let id = object.id ?? index
            objectsByID[id] = object
            visibility[String(id)] = isObjectVisible(object)
        }
        visibility = AudioReactiveScriptEngine.shared.resolveLayerVisibility(scene.objects, initial: visibility)

        func isVisibleWithParents(_ object: WESceneObject, visited: Set<Int> = []) -> Bool {
            let id = object.id ?? -1
            guard visibility[String(id)] ?? false else { return false }
            guard let parent = object.parent, !visited.contains(parent), let parentObject = objectsByID[parent] else { return true }
            return isVisibleWithParents(parentObject, visited: visited.union([id]))
        }
        for object in scene.objects {
            visibility[String(object.id ?? -1)] = isVisibleWithParents(object)
        }
        return visibility
    }

    private func isEffectVisible(_ effect: WEObjectEffect) -> Bool {
        if let property = effect.visibleUserProperty {
            guard let selectedValue = AudioReactiveScriptEngine.shared.userPropertyString(property) else { return false }
            if let condition = effect.visibleCondition {
                return normalizeVariant(condition) == normalizeVariant(selectedValue)
            }
            return selectedValue.caseInsensitiveCompare("true") == .orderedSame || selectedValue == "1"
        }
        return effect.visible != false
    }

    private func normalizeVariant(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private func materialEffects(_ pass: WEMaterialPass?) -> SceneMaterialEffects {
        let constants = pass?.constants ?? [:]
        var scripts: [String: String] = [:]
        func value(_ names: [String], default fallback: Float) -> Float {
            for (key, constant) in constants where names.contains(key.lowercased()) {
            if let script = constant.script { scripts[names[0]] = script }
                return Float(constant.value ?? Double(fallback))
            }
            return fallback
        }
        let shader = pass?.shader?.lowercased() ?? ""
        return SceneMaterialEffects(
            brightness: value(["brightness", "intensity", "overbright", "gain"], default: 1),
            contrast: value(["contrast", "contrastamount"], default: 1),
            saturation: value(["saturation", "saturationamount"], default: 1),
            bloom: value(["bloom", "bloomstrength", "glow", "strength"], default: shader.contains("bloom") ? 1 : 0),
            blur: value(["blur", "bluramount", "blurradius", "radius", "sigma"], default: shader.contains("blur") ? 1 : 0),
            exposure: value(["exposure", "exposurevalue"], default: 0),
            gamma: value(["gamma", "gammavalue"], default: 1),
            hue: value(["hue", "huerotation"], default: 0),
            bloomThreshold: value(["bloomthreshold", "threshold", "glowthreshold"], default: 0.7),
            transformAngle: value(["angle", "rotation"], default: 0),
            transformOffset: SIMD2<Float>(value(["offsetx", "xoffset"], default: 0), value(["offsety", "yoffset"], default: 0)),
            transformScale: SIMD2<Float>(value(["scalex", "xscale"], default: 1), value(["scaley", "yscale"], default: 1)),
            scripts: scripts
        )
    }

    private func loadMetalTexture(named name: String, materialDir: String, wallpaperDir: URL) -> SceneMetalTextureSource? {
        let materialDirPath = (materialDir as NSString).deletingLastPathComponent
        let root = materialDirPath.split(separator: "/").first.map(String.init) ?? "materials"
        let paths = Array(Set(["\(materialDirPath)/\(name).tex", "\(root)/\(name).tex", "\(name).tex"]))
        for path in paths {
            let data = pkgParser?.extractFile(named: path) ?? (try? Data(contentsOf: wallpaperDir.appending(path: path)))
            guard let data else { continue }
            let parser = TEXParser(data: data)
            if let animation = parser.extractAnimatedImages() { return .animated(animation) }
            if let texture = parser.extractCompressedTexture() { return .dxt(texture) }
        }
        return loadTexture(named: name, materialDir: materialDir, wallpaperDir: wallpaperDir).map(SceneMetalTextureSource.image)
    }

    private func buildMetalParticleSystem(_ object: WESceneObject, wallpaperDir: URL,
                                          objectsByID: [Int: WESceneObject]) -> SceneMetalParticleSystem? {
        guard let particlePath = object.particle,
              let particleSystem: WEParticleSystem = loadJSON(path: particlePath, wallpaperDir: wallpaperDir),
              let materialPath = particleSystem.material,
              let material: WEMaterial = loadJSON(path: materialPath, wallpaperDir: wallpaperDir),
              let textureName = material.passes?.first?.textures?.first else { return nil }
        let source = loadMetalTexture(named: textureName, materialDir: materialPath, wallpaperDir: wallpaperDir)
            ?? generateProceduralTexture(named: textureName).map(SceneMetalTextureSource.image)
        guard let source else { return nil }
        let spriteSheet = loadSpriteSheet(named: textureName, materialDir: materialPath, wallpaperDir: wallpaperDir)

        let emitter = particleSystem.emitter?.first
        let isSnowParticle = object.name?.localizedCaseInsensitiveContains("snow") == true
        let localOrigin = (emitter?.origin ?? object.origin ?? "0 0 0").parseVector3()
        let origin = SIMD2<Float>(Float(localOrigin.0), Float(localOrigin.1))
            + ancestorOrigin(for: object, sceneSize: .zero, objectsByID: objectsByID)
        let rate = Float((emitter?.rate ?? 100) * (object.instanceoverride?.rate?.value ?? 1))
        let rateScript = object.instanceoverride?.rate?.script ?? emitter?.$rate.script
        let radius = Float(emitter?.distancemax ?? 0)
        var lifetime: ClosedRange<Float> = 1...1
        var size: ClosedRange<Float> = Float(object.instanceoverride?.size ?? 1) * 20...Float(object.instanceoverride?.size ?? 1) * 20
        var minimumVelocity = SIMD2<Float>.zero
        var maximumVelocity = SIMD2<Float>.zero
        var alpha: ClosedRange<Float> = 1...1
        var minimumColor = SIMD4<Float>(repeating: 1)
        var maximumColor = SIMD4<Float>(repeating: 1)
        var minimumRotation: Float = 0
        var maximumRotation: Float = 0
        var minimumAngularVelocity: Float = 0
        var maximumAngularVelocity: Float = 0
        let particleRenderer = particleSystem.renderer?.first
        for initializer in particleSystem.initializer ?? [] {
            switch initializer.name {
            case "lifetimerandom": lifetime = Float(initializer.min?.doubleValue ?? 1)...Float(initializer.max?.doubleValue ?? 1)
            case "sizerandom":
                let multiplier = Float(object.instanceoverride?.size ?? 1)
                size = Float(initializer.min?.doubleValue ?? 20) * multiplier...Float(initializer.max?.doubleValue ?? 20) * multiplier
            case "velocityrandom":
                let minimum = initializer.min?.vectorValue ?? (0, 0, 0)
                let maximum = initializer.max?.vectorValue ?? (0, 0, 0)
                minimumVelocity = SIMD2<Float>(Float(minimum.0), Float(minimum.1))
                maximumVelocity = SIMD2<Float>(Float(maximum.0), Float(maximum.1))
            case "alpharandom": alpha = Float(initializer.min?.doubleValue ?? 1)...Float(initializer.max?.doubleValue ?? 1)
            case "colorrandom":
                if !isSnowParticle {
                    minimumColor = normalizedParticleColor(initializer.min?.vectorValue ?? (1, 1, 1))
                    maximumColor = normalizedParticleColor(initializer.max?.vectorValue ?? (1, 1, 1))
                }
            case "rotationrandom":
                minimumRotation = Float(initializer.min?.vectorValue.2 ?? 0)
                maximumRotation = Float(initializer.max?.vectorValue.2 ?? 0)
            case "angularvelocityrandom":
                minimumAngularVelocity = Float(initializer.min?.vectorValue.2 ?? 0)
                maximumAngularVelocity = Float(initializer.max?.vectorValue.2 ?? 0)
            default: break
            }
        }
        if isSnowParticle {
            minimumColor = SIMD4<Float>(1, 1, 1, 1)
            maximumColor = SIMD4<Float>(1, 1, 1, 1)
        }
        var gravity = SIMD2<Float>.zero
        var drag: Float = 0
        var fadeIn: Float = 0
        var fadeOut: Float = 1
        var dragScript: String?
        var fadeInScript: String?
        var fadeOutScript: String?
        var turbulence: Turbulence?
        var attractor: Attractor?
        let cursorControlPoint = particleSystem.controlpoint?.first(where: {
            $0.locktopointer == true || (($0.flags ?? 0) & 1) != 0
        }).map { controlPoint in
            let offset = (controlPoint.offset ?? "0 0 0").parseVector3()
            return CursorControlPoint(id: controlPoint.id ?? 0,
                                      offset: SIMD2<Float>(Float(offset.0), -Float(offset.1)))
        }
        for `operator` in particleSystem.operator ?? [] {
            switch `operator`.name {
            case "movement":
                let value = (`operator`.gravity ?? "0 0 0").parseVector3()
                gravity = SIMD2<Float>(Float(value.0), -Float(value.2 != 0 ? value.2 : value.1))
                drag = Float(`operator`.drag ?? 0)
                dragScript = `operator`.$drag.script
            case "alphafade":
                fadeIn = Float(`operator`.fadeintime ?? 0)
                fadeOut = Float(`operator`.fadeouttime ?? 1)
                fadeInScript = `operator`.$fadeintime.script
                fadeOutScript = `operator`.$fadeouttime.script
            case "turbulence":
                let mask = `operator`.mask?.vectorValue ?? (1, 1, 0)
                turbulence = Turbulence(scale: Float(`operator`.scale?.doubleValue ?? 0.005),
                                        speed: Float(`operator`.speedmin ?? 500)...Float(`operator`.speedmax ?? 1000),
                                        timeScale: Float(`operator`.timescale ?? 0.01),
                                        phase: Float(`operator`.phasemin ?? 0),
                                        mask: SIMD2<Float>(Float(mask.0), -Float(mask.1)))
            case "controlpointattract":
                let origin = `operator`.origin?.vectorValue ?? (0, 0, 0)
                attractor = Attractor(origin: SIMD2<Float>(Float(origin.0), -Float(origin.1)),
                                      strength: Float(`operator`.scale?.doubleValue ?? 100),
                                      threshold: Float(`operator`.threshold ?? 1000))
            default: break
            }
        }
        return SceneMetalParticleSystem(source: source, origin: origin, emissionRate: max(rate, 0),
                emissionRateScript: rateScript,
                                        maximumParticleCount: min(particleSystem.maxcount ?? 1000, 1000),
                                        spawnRadius: radius, lifetime: lifetime, size: size,
                                        minimumVelocity: minimumVelocity, maximumVelocity: maximumVelocity,
                                        gravity: gravity, drag: drag, dragScript: dragScript, alpha: alpha,
                                        minimumColor: minimumColor, maximumColor: maximumColor,
                                        minimumRotation: minimumRotation, maximumRotation: maximumRotation,
                                        minimumAngularVelocity: minimumAngularVelocity, maximumAngularVelocity: maximumAngularVelocity,
                                        rendererName: particleRenderer?.name ?? "sprite",
                                        trailLength: Float(particleRenderer?.length ?? 0.05),
                                        trailSegments: max(2, particleRenderer?.segments ?? 4),
                                        ropeSubdivision: max(1, particleRenderer?.subdivision ?? 4),
                                        fadeTrailAlpha: particleRenderer?.fadealpha ?? false,
                                        fadeTrailSize: particleRenderer?.fadesize ?? false,
                                        turbulence: turbulence, attractor: attractor,
                                        cursorControlPoint: cursorControlPoint,
                                        emitterControlPoint: emitter?.controlpoint,
                                        spriteSheet: spriteSheet,
                                        animationMode: particleSystem.animationmode ?? "sequence",
                                        sequenceMultiplier: Float(particleSystem.sequencemultiplier ?? 1),
                                        fadeIn: fadeIn, fadeOut: fadeOut,
                                        fadeInScript: fadeInScript, fadeOutScript: fadeOutScript,
                                        blending: material.passes?.first?.blending?.lowercased() ?? "translucent")
    }

    private func loadSpriteSheet(named name: String, materialDir: String, wallpaperDir: URL) -> SpriteSheet? {
        struct TextureMetadata: Decodable {
            struct Sequence: Decodable { let frames: Int; let width: Double; let height: Double; let duration: Double }
            let spritesheetsequences: [Sequence]?
        }
        let materialDirectory = (materialDir as NSString).deletingLastPathComponent
        let root = materialDirectory.split(separator: "/").first.map(String.init) ?? "materials"
        let candidates = ["\(materialDirectory)/\(name).tex-json", "\(root)/\(name).tex-json", "\(name).tex-json"]
        for candidate in candidates {
            let data = pkgParser?.extractFile(named: candidate) ?? (try? Data(contentsOf: wallpaperDir.appending(path: candidate)))
            guard let data, let metadata = try? JSONDecoder().decode(TextureMetadata.self, from: data),
                  let sequence = metadata.spritesheetsequences?.first, sequence.frames > 0,
                  sequence.width > 0, sequence.height > 0 else { continue }
            let columns = max(1, Int((Double(sequence.frames) * sequence.width / sequence.height).squareRoot()))
            let rows = max(1, Int(ceil(Double(sequence.frames) / Double(columns))))
            return SpriteSheet(columns: columns, rows: rows, frames: sequence.frames, duration: Float(sequence.duration))
        }
        return nil
    }

    private func normalizedParticleColor(_ color: (Double, Double, Double)) -> SIMD4<Float> {
        guard color.0.isFinite, color.1.isFinite, color.2.isFinite,
              max(color.0, color.1, color.2) > 0 else {
            return SIMD4<Float>(1, 1, 1, 1)
        }
        let scale = max(color.0, color.1, color.2) > 1 ? 255.0 : 1.0
        return SIMD4<Float>(Float(color.0 / scale), Float(color.1 / scale), Float(color.2 / scale), 1)
    }

    // MARK: - Image Objects

    private func buildImageNode(_ obj: WESceneObject, wallpaperDir: URL) -> SKSpriteNode? {
        guard let imagePath = obj.image else { return nil }

        // Load model JSON → material JSON → texture
        let model: WEModel? = loadJSON(path: imagePath, wallpaperDir: wallpaperDir)
        guard let materialPath = model?.material else {
            print("[SceneVM] No material for image object '\(obj.name ?? "")' (model path: \(imagePath))")
            return nil
        }

        let material: WEMaterial? = loadJSON(path: materialPath, wallpaperDir: wallpaperDir)
        guard let textureName = material?.passes?.first?.textures?.first else {
            print("[SceneVM] No texture in material '\(materialPath)' (material decoded: \(material != nil))")
            return nil
        }

        // Load texture: try .tex file first, then common image formats
        Self.log("Loading texture '\(textureName)' for '\(obj.name ?? "")'")
        let image = loadTexture(named: textureName, materialDir: materialPath, wallpaperDir: wallpaperDir)
        guard let image = image else {
            Self.log("FAILED to load texture '\(textureName)' from material dir '\(materialPath)'")
            return nil
        }
        Self.log("Texture loaded: \(image.size)")

        let texture = SKTexture(image: image)
        let node = SKSpriteNode(texture: texture)

        // Size from object, or use pixel dimensions (not point size, which is halved on Retina)
        if let sizeStr = obj.size {
            let (w, h) = sizeStr.parseVector2()
            node.size = CGSize(width: w, height: h)
        } else {
            let pixelW = image.representations.first?.pixelsWide ?? Int(image.size.width)
            let pixelH = image.representations.first?.pixelsHigh ?? Int(image.size.height)
            node.size = CGSize(width: pixelW, height: pixelH)
        }

        // Position: WE uses top-left origin with Y-down, SpriteKit uses bottom-left with Y-up
        if let originStr = obj.origin {
            let (x, y, _) = originStr.parseVector3()
            node.position = CGPoint(x: x, y: y)
        }

        // Alpha
        node.alpha = CGFloat(obj.alpha ?? 1.0)

        // Color tint
        if let colorStr = obj.color {
            let c = colorStr.parseColor()
            node.color = NSColor(red: c.r, green: c.g, blue: c.b, alpha: 1.0)
            node.colorBlendFactor = (obj.colorBlendMode ?? 0) > 0 ? 1.0 : 0.0
        }

        // Blend mode from material
        if let blending = material?.passes?.first?.blending {
            switch blending {
            case "additive": node.blendMode = .add
            case "translucent": node.blendMode = .alpha
            default: node.blendMode = .alpha
            }
        }

        return node
    }

    // MARK: - Particle Objects

    private func buildParticleNode(_ obj: WESceneObject, wallpaperDir: URL, sceneSize: CGSize) -> SKNode? {
        guard let particlePath = obj.particle else { return nil }

        let particleSystem: WEParticleSystem? = loadJSON(path: particlePath, wallpaperDir: wallpaperDir)
        guard let ps = particleSystem else {
            print("[SceneVM] Failed to load particle system '\(particlePath)'")
            return nil
        }

        let emitter = SKEmitterNode()

        // Particle texture from material
        if let materialPath = ps.material {
            let material: WEMaterial? = loadJSON(path: materialPath, wallpaperDir: wallpaperDir)
            if let texName = material?.passes?.first?.textures?.first {
                let texImage = loadTexture(named: texName, materialDir: materialPath, wallpaperDir: wallpaperDir)
                    ?? generateProceduralTexture(named: texName)
                if let img = texImage {
                    emitter.particleTexture = SKTexture(image: img)
                }
            }

            // Blend mode
            if let blending = material?.passes?.first?.blending {
                emitter.particleBlendMode = blending == "additive" ? .add : .alpha
            }
        }

        // Emitter properties
        if let em = ps.emitter?.first {
            emitter.particleBirthRate = CGFloat(em.rate ?? 100)

            // Apply instance override rate
            if let overrideRate = obj.instanceoverride?.rate?.value {
                emitter.particleBirthRate *= CGFloat(overrideRate)
            }

            // Emission area from distancemax (sphererandom emitter)
            if em.name == "sphererandom" {
                let dist = CGFloat(em.distancemax ?? 100)
                emitter.particlePositionRange = CGVector(dx: dist * 2, dy: dist * 2)
            }
        }

        // Initializers
        for ini in ps.initializer ?? [] {
            switch ini.name {
            case "lifetimerandom":
                let minLife = ini.min?.doubleValue ?? 1
                let maxLife = ini.max?.doubleValue ?? 1
                emitter.particleLifetime = CGFloat((minLife + maxLife) / 2)
                emitter.particleLifetimeRange = CGFloat(maxLife - minLife)

            case "sizerandom":
                let minSize = ini.min?.doubleValue ?? 1
                let maxSize = ini.max?.doubleValue ?? 1
                let avgSize = (minSize + maxSize) / 2
                // Apply instance override size
                let sizeMultiplier = obj.instanceoverride?.size ?? 1.0
                emitter.particleSize = CGSize(width: avgSize * sizeMultiplier, height: avgSize * sizeMultiplier)
                emitter.particleScaleRange = CGFloat((maxSize - minSize) / avgSize) * CGFloat(sizeMultiplier)

            case "velocityrandom":
                let minV = ini.min?.vectorValue ?? (0, 0, 0)
                let maxV = ini.max?.vectorValue ?? (0, 0, 0)
                // Use Y component for speed (primary direction in most WE particles)
                let avgSpeedY = (minV.1 + maxV.1) / 2
                let avgSpeedX = (minV.0 + maxV.0) / 2
                let speed = sqrt(avgSpeedX * avgSpeedX + avgSpeedY * avgSpeedY)
                emitter.particleSpeed = CGFloat(speed)
                emitter.particleSpeedRange = CGFloat(abs(maxV.1 - minV.1) / 2)
                // Emission angle: atan2 of velocity direction
                if speed > 0 {
                    // SpriteKit Y is up, WE Y is down for velocity
                    emitter.emissionAngle = CGFloat(atan2(-avgSpeedY, avgSpeedX))
                    emitter.emissionAngleRange = 0.1
                }

            case "alpharandom":
                let minA = ini.min?.doubleValue ?? 1
                let maxA = ini.max?.doubleValue ?? 1
                emitter.particleAlpha = CGFloat((minA + maxA) / 2)
                emitter.particleAlphaRange = CGFloat(maxA - minA)

            case "colorrandom":
                if let maxColor = ini.max?.vectorValue {
                    // Colors in WE particles are 0-255
                    emitter.particleColor = NSColor(
                        red: maxColor.0 / 255.0,
                        green: maxColor.1 / 255.0,
                        blue: maxColor.2 / 255.0,
                        alpha: 1.0)
                }

            default:
                break
            }
        }

        // Operators
        for op in ps.operator ?? [] {
            switch op.name {
            case "movement":
                if let gravityStr = op.gravity {
                    let (gx, gy, gz) = gravityStr.parseVector3()
                    // WE Z-axis maps to SpriteKit Y acceleration (WE uses Z for depth/vertical)
                    emitter.xAcceleration = CGFloat(gx)
                    // In WE, positive Z gravity pulls "forward", map to Y-down in SK
                    emitter.yAcceleration = CGFloat(-gz)
                    if gy != 0 && gz == 0 {
                        emitter.yAcceleration = CGFloat(-gy)
                    }
                }

            case "alphafade":
                // Fade in/out over lifetime
                let fadeIn = op.fadeintime ?? 0
                let fadeOut = op.fadeouttime ?? 1
                // SpriteKit particleAlphaSpeed: rate of alpha change per second
                // Approximate: particles fade in quickly and fade out over remaining lifetime
                if fadeOut < 1.0 {
                    emitter.particleAlphaSpeed = CGFloat(-1.0 / max(emitter.particleLifetime * CGFloat(1 - fadeOut), 0.1))
                }
                _ = fadeIn // Used implicitly through initial alpha ramp

            default:
                break
            }
        }

        // Renderer: spritetrail gets elongated aspect ratio
        if let renderer = ps.renderer?.first, renderer.name == "spritetrail" {
            let trailLength = CGFloat(renderer.maxlength ?? 50)
            emitter.particleSize = CGSize(width: 2, height: trailLength)
            // Align particles to movement direction
            emitter.particleRotation = emitter.emissionAngle
        }

        // Position from object origin
        if let originStr = obj.origin {
            let (x, y, _) = originStr.parseVector3()
            emitter.position = CGPoint(x: x, y: y)
        }

        // Scale from object
        if let scaleStr = obj.scale {
            let (sx, sy, _) = scaleStr.parseVector3()
            emitter.xScale = CGFloat(sx)
            emitter.yScale = CGFloat(sy)
        }

        // Max particles
        emitter.numParticlesToEmit = 0 // infinite

        return emitter
    }

    // MARK: - Asset Loading

    private func loadJSON<T: Decodable>(path: String, wallpaperDir: URL) -> T? {
        // Try PKG first
        if let parser = pkgParser, let data = parser.extractFile(named: path) {
            return try? JSONDecoder().decode(T.self, from: data)
        }
        // Fall back to loose file
        let url = wallpaperDir.appending(path: path)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func loadTexture(named name: String, materialDir: String, wallpaperDir: URL) -> NSImage? {
        // Build candidate .tex paths: relative to material dir, then relative to materials/ root
        let materialDirPath = (materialDir as NSString).deletingLastPathComponent
        var texPaths = [String]()
        if !materialDirPath.isEmpty {
            texPaths.append("\(materialDirPath)/\(name).tex")
        }
        // Also try materials/{name}.tex for textures with embedded paths (e.g. "workshop/xxx/foo")
        let materialsRoot = materialDirPath.split(separator: "/").first.map(String.init) ?? "materials"
        let rootPath = "\(materialsRoot)/\(name).tex"
        if !texPaths.contains(rootPath) {
            texPaths.append(rootPath)
        }
        texPaths.append("\(name).tex")

        for texPath in texPaths {
            // Try .tex from PKG
            if let parser = pkgParser, let texData = parser.extractFile(named: texPath) {
                Self.log("  TEX from PKG '\(texPath)' size=\(texData.count)")
                let texParser = TEXParser(data: Data(texData))  // Copy to reset indices
                if let image = texParser.extractImage() {
                    return image
                }
                Self.log("  TEXParser.extractImage() returned nil for '\(texPath)'")
            }

            // Try .tex from loose file
            let texURL = wallpaperDir.appending(path: texPath)
            if let texData = try? Data(contentsOf: texURL) {
                let texParser = TEXParser(data: texData)
                if let image = texParser.extractImage() {
                    return image
                }
            }
        }

        // Try common image formats directly
        for ext in ["png", "jpg", "jpeg", "gif"] {
            let imgPath = materialDirPath.isEmpty ? "\(name).\(ext)" : "\(materialDirPath)/\(name).\(ext)"
            if let parser = pkgParser, let imgData = parser.extractFile(named: imgPath) {
                if let image = NSImage(data: imgData) { return image }
            }
            let imgURL = wallpaperDir.appending(path: imgPath)
            if let image = NSImage(contentsOf: imgURL) { return image }
        }

        Self.log("  No texture found for '\(name)'")
        return nil
    }

    /// Generate simple procedural textures for built-in particle names
    private func generateProceduralTexture(named name: String) -> NSImage? {
        let size: CGFloat = 32

        switch name {
        case "particle/drop":
            // Elongated raindrop: bright center, soft edges
            return generateRadialGradient(size: CGSize(width: 4, height: 16), color: .white)

        case _ where name.contains("halo"):
            // Soft circular glow
            return generateRadialGradient(size: CGSize(width: size, height: size), color: .white)

        default:
            // Generic soft circle
            return generateRadialGradient(size: CGSize(width: size, height: size), color: .white)
        }
    }

    private func generateRadialGradient(size: CGSize, color: NSColor) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()

        let ctx = NSGraphicsContext.current!.cgContext
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        // Convert to RGB color space to guarantee 4 components (r, g, b, a)
        let rgbColor = color.usingColorSpace(.deviceRGB) ?? color
        let r = rgbColor.redComponent
        let g = rgbColor.greenComponent
        let b = rgbColor.blueComponent
        let a = rgbColor.alphaComponent
        let colors = [
            CGColor(colorSpace: colorSpace, components: [r, g, b, a])!,
            CGColor(colorSpace: colorSpace, components: [r, g, b, 0])!
        ] as CFArray
        let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1])!

        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2
        ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                               endCenter: center, endRadius: radius, options: [])

        image.unlockFocus()
        return image
    }

}
