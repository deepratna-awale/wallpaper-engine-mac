import SwiftUI
import AVFoundation

private struct SceneInspectorItem: Identifiable {
    let id: String
    let name: String
    let kind: String
    let sourcePath: String
    let materialPath: String?
    let texturePaths: [String]
    let shaderPaths: [String]
    var rawObject: String
    var rawMaterial: String?
    var rawParticle: String?
    let visible: Bool
    let isVersion: Bool
    let versionName: String?
    let versionValue: String?
    let effects: [SceneInspectorEffect]
    /// Video wallpapers have no authored object behind the layer, so it is description-only.
    var isSynthetic = false
}

private struct SceneInspectorEffect: Identifiable {
    let id: String
    let name: String
    let title: String
    let maskPath: String?
    let controls: [SceneInspectorEffectControl]
    var combos: [SceneInspectorEffectCombo] = []
}

/// A `// [COMBO]` switch of the effect's shaders that WE's editor shows.
private struct SceneInspectorEffectCombo: Identifiable {
    let id: String
    let effectID: String
    /// The preprocessor name, which the override is stored under.
    let combo: String
    let title: String
    /// WE's options as (title, value, the editor's group heading); an on/off switch when empty.
    let options: [(title: String, value: Int, group: String?)]
    /// Other combos' values this one is shown for, as WE's `require`.
    var requirements: [String: Int] = [:]
}

private struct SceneInspectorEffectControl: Identifiable {
    let id: String
    let effectID: String
    let key: String
    let component: Int
    let title: String
    let minimum: Double
    let maximum: Double
    let defaultValue: Double
    let displaysDegrees: Bool
    /// From the uniform's annotation (`int`, `"type":"color"`, `linked`).
    var isInteger = false
    var isColor = false
    var isLinked = false
    var componentCount = 1
}

private struct SceneInspectorTexture: Identifiable {
    let id: String
    let path: String
    let image: NSImage
}

private enum SceneHorizontalSnap {
    case left, center, right
}

private enum SceneVerticalSnap {
    case top, center, bottom
}

private final class SceneInspectorModel: ObservableObject {
    @Published var items: [SceneInspectorItem] = []
    @Published var errorMessage: String?
    @Published var decodedTextures: [SceneInspectorTexture] = []
    @Published var decodedMasks: [String: SceneInspectorTexture] = [:]
    @Published var effectValues: [String: Double] = [:]
    @Published var effectEnabled: [String: Bool] = [:]
    @Published var comboValues: [String: Int] = [:]
    /// Linked vec2 parameters (by `effectID:key`) currently edited as one value.
    @Published var linkedParameters: Set<String> = []
    @Published var decodedItemID: String?
    @Published var loadingItemID: String?
    private(set) var initiallySelectedID: String?
    private var sceneSize = SIMD2<Double>(1920, 1080)

    private let directory: URL
    private let package: PKGParser?
    /// The stores its edits go to: the selected displays', or the shared one while synced.
    private let targets: WallpaperPropertyTargets
    private var textureLoadGeneration = 0
    private var pendingSave: DispatchWorkItem?

    init(wallpaper: WEWallpaper, scopes: [WallpaperPropertyScope]) {
        directory = wallpaper.wallpaperDirectory
        targets = WallpaperPropertyTargets(wallpaper: wallpaper, scopes: scopes)
        let scenePath = wallpaper.project.file
        let packageURL = directory.appending(path: (scenePath as NSString).deletingPathExtension + ".pkg")
        package = try? PKGParser(url: packageURL)

        func data(_ path: String) -> Data? {
            package?.extractFile(named: path) ?? (try? Data(contentsOf: directory.appending(path: path)))
        }
        func rawJSON(_ path: String) -> String? {
            guard let data = data(path),
                  let json = try? JSONSerialization.jsonObject(with: data),
                  let formatted = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else { return nil }
            return String(data: formatted, encoding: .utf8)
        }
        guard let sceneData = data(scenePath),
              let scene = try? JSONDecoder().decode(WEScene.self, from: sceneData),
              let sceneJSON = try? JSONSerialization.jsonObject(with: sceneData) as? [String: Any],
              let rawObjects = sceneJSON["objects"] as? [[String: Any]] else {
            if SceneWallpaperViewModel.isVideoType(wallpaper.project.type) {
                buildVideoLayers(for: wallpaper)
            } else {
                errorMessage = "Unable to read the scene definition."
            }
            return
        }
                sceneSize = Self.sceneSize(for: scene)

        let storedValues = targets.storedValues
        items = scene.objects.enumerated().map { index, object in
            let objectID = object.id ?? index
            var rawObject = rawObjects.indices.contains(index) ? prettyJSON(rawObjects[index]) : "{}"
            if let origin = storedValues["_owe_scene_object_\(objectID)_origin"] {
                rawObject = Self.rawObject(rawObject, settingOrigin: origin)
            }
            let visible = storedValues[sceneObjectVisibilityKey(objectID: objectID)].map { $0 != "false" }
                ?? object.visible ?? true
            let effects = makeEffects(object.effects ?? [], objectID: objectID, storedValues: storedValues)
            let version = Self.versionName(from: object.name)
            if let imagePath = object.image {
                let model: WEModel? = data(imagePath).flatMap { try? JSONDecoder().decode(WEModel.self, from: $0) }
                let materialPath = model?.material
                let material: WEMaterial? = materialPath.flatMap { data($0) }.flatMap { try? JSONDecoder().decode(WEMaterial.self, from: $0) }
                let passes = material?.passes ?? []
                return SceneInspectorItem(id: String(object.id ?? index), name: object.name ?? "Image \(index + 1)",
                                          kind: "Image", sourcePath: imagePath, materialPath: materialPath,
                                          texturePaths: passes.flatMap { $0.textures ?? [] },
                                          shaderPaths: passes.compactMap(\.shader), rawObject: rawObject,
                                          rawMaterial: materialPath.flatMap(rawJSON), rawParticle: nil,
                                          visible: visible,
                                          isVersion: version != nil, versionName: version,
                                          versionValue: object.visibleCondition, effects: effects)
            }
            if let particlePath = object.particle {
                let particle: WEParticleSystem? = data(particlePath).flatMap { try? JSONDecoder().decode(WEParticleSystem.self, from: $0) }
                let materialPath = particle?.material
                let material: WEMaterial? = materialPath.flatMap { data($0) }.flatMap { try? JSONDecoder().decode(WEMaterial.self, from: $0) }
                let passes = material?.passes ?? []
                return SceneInspectorItem(id: String(object.id ?? index), name: object.name ?? "Particle \(index + 1)",
                                          kind: "Particle", sourcePath: particlePath, materialPath: materialPath,
                                          texturePaths: passes.flatMap { $0.textures ?? [] },
                                          shaderPaths: passes.compactMap(\.shader), rawObject: rawObject,
                                          rawMaterial: materialPath.flatMap(rawJSON), rawParticle: rawJSON(particlePath),
                                          visible: visible,
                                          isVersion: false, versionName: nil, versionValue: nil, effects: effects)
            }
            return SceneInspectorItem(id: String(object.id ?? index), name: object.name ?? "Object \(index + 1)",
                                      kind: "Other", sourcePath: "", materialPath: nil, texturePaths: [], shaderPaths: [],
                                      rawObject: rawObject, rawMaterial: nil, rawParticle: nil,
                                      visible: visible,
                                      isVersion: false, versionName: nil, versionValue: nil, effects: effects)
        }
                        let selectedVersion = storedValues["version"]
                        initiallySelectedID = items.first { $0.versionValue == selectedVersion }?.id ?? items.first?.id
    }

    private static func versionName(from name: String?) -> String? {
        guard let name, let range = name.range(of: #"_(\d+)$"#, options: .regularExpression) else { return nil }
        let number = name[range].dropFirst()
        return "Version \(number)"
    }

    /// Wallpaper Engine renders a video through its `scenes/videoplayer` scene, and the Metal path
    /// here does the same: one video layer plus the shared effect stack. There is no scene.json to
    /// read, so those layers are described directly instead of leaving the inspector empty.
    private func buildVideoLayers(for wallpaper: WEWallpaper) {
        let file = wallpaper.project.file
        let url = directory.appending(path: file)
        let syncKeys = ["zoom", "pace", "tilt", "saturation"]
        let enabledSync = syncKeys.filter { VideoMusicSyncSettings.bool(wallpaper, "\($0)Enabled") }

        items = [
            SceneInspectorItem(id: "video", name: "Video", kind: "Video", sourcePath: file,
                               materialPath: nil, texturePaths: [], shaderPaths: [],
                               rawObject: prettyJSON(["file": file, "status": "Reading media…"]),
                               rawMaterial: nil, rawParticle: nil, visible: true,
                               isVersion: false, versionName: nil, versionValue: nil,
                               effects: [], isSynthetic: true),
            SceneInspectorItem(id: "effects", name: "Effects", kind: "Effect Stack", sourcePath: "",
                               materialPath: nil, texturePaths: [], shaderPaths: [],
                               rawObject: prettyJSON([
                                   "musicSync": enabledSync.isEmpty ? "none" : enabledSync.joined(separator: ", "),
                                   "note": "Scene effects are toggled under User Scene Settings."
                               ]),
                               rawMaterial: nil, rawParticle: nil, visible: true,
                               isVersion: false, versionName: nil, versionValue: nil,
                               effects: [], isSynthetic: true)
        ]
        initiallySelectedID = "video"

        Task { [weak self] in
            let asset = AVURLAsset(url: url)
            let videoTrack = try? await asset.loadTracks(withMediaType: .video).first
            let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first
            let duration = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) }
            let size = try? await videoTrack?.load(.naturalSize)
            let frameRate = try? await videoTrack?.load(.nominalFrameRate)

            var summary: [String: Any] = ["file": file]
            if let size { summary["resolution"] = "\(Int(size.width)) x \(Int(size.height))" }
            if let duration, duration.isFinite { summary["duration"] = String(format: "%.2f s", duration) }
            if let frameRate { summary["frameRate"] = String(format: "%.2f fps", frameRate) }
            summary["hasAudio"] = audioTrack != nil

            await MainActor.run { [weak self] in
                guard let self else { return }
                if let index = self.items.firstIndex(where: { $0.id == "video" }) {
                    self.items[index].rawObject = prettyJSON(summary)
                }
                guard audioTrack != nil else { return }
                var audioSummary: [String: Any] = ["file": file, "track": "embedded soundtrack"]
                if let duration, duration.isFinite {
                    audioSummary["duration"] = String(format: "%.2f s", duration)
                }
                let audio = SceneInspectorItem(id: "audio", name: "Audio", kind: "Audio", sourcePath: file,
                                               materialPath: nil, texturePaths: [], shaderPaths: [],
                                               rawObject: prettyJSON(audioSummary),
                                               rawMaterial: nil, rawParticle: nil, visible: true,
                                               isVersion: false, versionName: nil, versionValue: nil,
                                               effects: [], isSynthetic: true)
                self.items.insert(audio, at: 1)
            }
        }
    }

    private func makeEffects(_ effects: [WEObjectEffect], objectID: Int,
                             storedValues: [String: String]) -> [SceneInspectorEffect] {
        let wallpaperDirectory = directory
        let assets = WallpaperEngineAssets.directory
        let labels = WallpaperEngineLabels.load()
        let readFile: (String) -> Data? = { path in
            FileManager.default.contents(atPath: wallpaperDirectory.appending(path: path).path)
                ?? assets.flatMap { FileManager.default.contents(atPath: $0.appending(path: path).path) }
        }
        return effects.enumerated().map { effectIndex, effect in
            let name = ((effect.file as NSString).deletingLastPathComponent as NSString).lastPathComponent.lowercased()
            let effectID = "\(objectID):\(effectIndex)"
            let enabledKey = sceneAuthoredEffectEnabledKey(objectID: objectID, effectIndex: effectIndex)
            effectEnabled[effectID] = storedValues[enabledKey].map { $0.lowercased() != "false" }
                ?? effect.visible.map { $0 != false } ?? true
            // Parameters come from the effect's own shaders, as in WE's editor: its ranges,
            // defaults and labels, nothing widened or renamed.
            let parameters = SceneEffectParameters.parameters(for: effect.file, readFile: readFile)
            let authored = effect.passes?.first?.constants ?? [:]
            var controls: [SceneInspectorEffectControl] = []
            for parameter in parameters {
                let authoredValue = authored.first { $0.key.caseInsensitiveCompare(parameter.materialKey) == .orderedSame }?
                    .value.valueSource.flatMap { source -> [Double]? in
                        if case .literal(let value) = source { return value.components.map(Double.init) }
                        return nil
                    }
                let baseValues = authoredValue ?? parameter.defaultValue
                let overrideKey = sceneAuthoredEffectOverrideKey(objectID: objectID, effectIndex: effectIndex,
                                                                  parameter: parameter.materialKey)
                let overrideValues = storedValues[overrideKey]?
                    .split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
                let values = overrideValues?.isEmpty == false ? overrideValues! : baseValues
                let title = labels.translation(parameter.label) ?? parameter.title
                let count = parameter.defaultValue.count
                if parameter.isLinked, count == 2, values.count >= 2, values[0] == values[1] {
                    linkedParameters.insert("\(effectID):\(parameter.materialKey)")
                }
                for component in parameter.defaultValue.indices {
                    let controlID = "\(effectID):\(parameter.materialKey):\(component)"
                    let value = values.indices.contains(component) ? values[component] : parameter.defaultValue[component]
                    effectValues[controlID] = value
                    // A colour is one picker, titled as WE titles it.
                    let suffix = count > 1 && !parameter.isColor ? " " + ["X", "Y", "Z", "W"][min(component, 3)] : ""
                    controls.append(SceneInspectorEffectControl(
                        id: controlID, effectID: effectID, key: parameter.materialKey, component: component,
                        title: title + suffix,
                        minimum: parameter.minimum, maximum: parameter.maximum,
                        defaultValue: baseValues.indices.contains(component) ? baseValues[component] : 0,
                        displaysDegrees: false, isInteger: parameter.isInteger, isColor: parameter.isColor,
                        isLinked: parameter.isLinked, componentCount: count))
                }
            }
            let authoredCombos = effect.passes?.first?.combos ?? [:]
            var combos: [SceneInspectorEffectCombo] = []
            for combo in SceneEffectParameters.combos(for: effect.file, readFile: readFile) where combo.isEditable {
                let comboID = "\(effectID):combo:\(combo.combo)"
                let key = sceneAuthoredEffectOverrideKey(objectID: objectID, effectIndex: effectIndex, parameter: SceneEffectParameters.comboOverrideKey(combo.combo))
                let authoredValue = authoredCombos.first { $0.key.caseInsensitiveCompare(combo.combo) == .orderedSame }?.value
                comboValues[comboID] = storedValues[key].flatMap { Int($0) } ?? authoredValue ?? combo.defaultValue
                combos.append(SceneInspectorEffectCombo(
                    id: comboID, effectID: effectID, combo: combo.combo,
                    title: labels.translation(combo.label) ?? SceneEffectParameters.title(combo.label),
                    options: combo.options.map { option in
                        (labels.translation(option.label) ?? option.english ?? SceneEffectParameters.title(option.label),
                         option.value, option.group.map { labels.translation($0) ?? Self.groupTitle($0) })
                    },
                    requirements: combo.requirements))
            }
            let maskPath = effect.passes?.first?.textures?.compactMap { $0 }.first
            return SceneInspectorEffect(id: effectID, name: name,
                                        title: name.replacingOccurrences(of: "_", with: " ").capitalized,
                                        maskPath: maskPath, controls: controls, combos: combos)
        }
    }

    /// A blend-mode group heading without WE's translation table: its English text.
    private static func groupTitle(_ key: String) -> String {
        [WEImageBlendModes.nativeGroup, WEImageBlendModes.emulatedGroup].first { $0.label == key }?.english
            ?? SceneEffectParameters.title(key)
    }

    private static func displayEffectValue(_ value: Double, key: String) -> Double {
        value
    }

    func setEffectValue(_ value: Double, control: SceneInspectorEffectControl) {
        effectValues[control.id] = value
        // A linked vec2 moves both components together, as WE's linked slider does.
        if control.isLinked, linkedParameters.contains("\(control.effectID):\(control.key)") {
            for component in 0..<control.componentCount {
                effectValues["\(control.effectID):\(control.key):\(component)"] = value
            }
        }
        let prefix = "\(control.effectID):\(control.key):"
        let components = effectValues.keys.filter { $0.hasPrefix(prefix) }
            .sorted { (Int($0.split(separator: ":").last!) ?? 0) < (Int($1.split(separator: ":").last!) ?? 0) }
            .compactMap { effectValues[$0] }
        let parts = control.effectID.split(separator: ":")
        guard parts.count == 2, let objectID = Int(parts[0]), let effectIndex = Int(parts[1]) else { return }
        let key = sceneAuthoredEffectOverrideKey(objectID: objectID, effectIndex: effectIndex,
                                                 parameter: control.key)
        var values = targets.storedValues
        values[key] = components.map { String($0) }.joined(separator: " ")
        persist(values)
    }

    func isLinked(_ control: SceneInspectorEffectControl) -> Bool {
        linkedParameters.contains("\(control.effectID):\(control.key)")
    }

    /// WE's link toggle: linking copies X into Y.
    func setLinked(_ linked: Bool, control: SceneInspectorEffectControl) {
        let id = "\(control.effectID):\(control.key)"
        if linked {
            linkedParameters.insert(id)
            setEffectValue(effectValues["\(id):0"] ?? control.defaultValue, control: control)
        } else {
            linkedParameters.remove(id)
        }
    }

    /// WE shows a combo only while the combos it `require`s have those values.
    func requirementsHold(_ combo: SceneInspectorEffectCombo, in effect: SceneInspectorEffect) -> Bool {
        combo.requirements.allSatisfy { name, value in
            effect.combos.first { $0.combo == name }.map { comboValue($0) == value } ?? true
        }
    }

    func comboValue(_ combo: SceneInspectorEffectCombo) -> Int {
        comboValues[combo.id] ?? 0
    }

    func setComboValue(_ value: Int, combo: SceneInspectorEffectCombo) {
        comboValues[combo.id] = value
        let parts = combo.effectID.split(separator: ":")
        guard parts.count == 2, let objectID = Int(parts[0]), let effectIndex = Int(parts[1]) else { return }
        let key = sceneAuthoredEffectOverrideKey(objectID: objectID, effectIndex: effectIndex, parameter: SceneEffectParameters.comboOverrideKey(combo.combo))
        var values = targets.storedValues
        values[key] = String(value)
        persist(values)
    }

    func displayedEffectValue(for control: SceneInspectorEffectControl) -> Double {
        let value = effectValues[control.id] ?? control.defaultValue
        return control.displaysDegrees ? value * 180 / .pi : value
    }

    func effectColor(for control: SceneInspectorEffectControl) -> Color {
        let prefix = "\(control.effectID):\(control.key):"
        let values = effectValues.keys.filter { $0.hasPrefix(prefix) }.sorted().compactMap { effectValues[$0] }
        // WE's colour uniforms are normalised 0...1.
        return Color(red: values.indices.contains(0) ? values[0] : 1,
                     green: values.indices.contains(1) ? values[1] : 1,
                     blue: values.indices.contains(2) ? values[2] : 1)
    }

    func setEffectColor(_ color: Color, control: SceneInspectorEffectControl) {
        let nsColor = NSColor(color).usingColorSpace(.deviceRGB) ?? .white
        let rgb = [nsColor.redComponent, nsColor.greenComponent, nsColor.blueComponent]
        let prefix = "\(control.effectID):\(control.key):"
        for (index, id) in effectValues.keys.filter({ $0.hasPrefix(prefix) }).sorted().enumerated() where index < 3 {
            effectValues[id] = rgb[index]
        }
        let parts = control.effectID.split(separator: ":")
        guard parts.count == 2, let objectID = Int(parts[0]), let effectIndex = Int(parts[1]) else { return }
        let key = sceneAuthoredEffectOverrideKey(objectID: objectID, effectIndex: effectIndex, parameter: control.key)
        var values = targets.storedValues
        values[key] = rgb.map(String.init).joined(separator: " ")
        persist(values)
    }

    func setDisplayedEffectValue(_ value: Double, control: SceneInspectorEffectControl) {
        setEffectValue(control.displaysDegrees ? value * .pi / 180 : value, control: control)
    }

    func musicSyncEnabled(for control: SceneInspectorEffectControl) -> Bool {
        let key = musicSyncKey(for: control)
        let values = targets.storedValues
        return (values[key] ?? "false").lowercased() == "true"
    }

    func setMusicSyncEnabled(_ enabled: Bool, for control: SceneInspectorEffectControl) {
        var values = targets.storedValues
        values[musicSyncKey(for: control)] = enabled ? "true" : "false"
        if values[musicAmountKey(for: control)] == nil {
            values[musicAmountKey(for: control)] = "0"
        }
        persist(values)
    }

    func musicAmount(for control: SceneInspectorEffectControl) -> Double {
        let values = targets.storedValues
        let raw = Double(values[musicAmountKey(for: control)] ?? "0") ?? 0
        return control.displaysDegrees ? raw * 180 / .pi : raw
    }

    func setMusicAmount(_ amount: Double, for control: SceneInspectorEffectControl) {
        var values = targets.storedValues
        values[musicAmountKey(for: control)] = String(control.displaysDegrees ? amount * .pi / 180 : amount)
        persist(values)
    }

    private func overrideKey(for control: SceneInspectorEffectControl) -> String? {
        let parts = control.effectID.split(separator: ":")
        guard parts.count == 2, let objectID = Int(parts[0]), let effectIndex = Int(parts[1]) else { return nil }
        let key = sceneAuthoredEffectOverrideKey(objectID: objectID, effectIndex: effectIndex, parameter: control.key)
        let prefix = "\(control.effectID):\(control.key):"
        let componentCount = effectValues.keys.filter { $0.hasPrefix(prefix) }.count
        return componentCount > 1 ? "\(key)_\(control.component)" : key
    }

    private func musicSyncKey(for control: SceneInspectorEffectControl) -> String {
        "\(overrideKey(for: control) ?? control.id)_musicSync"
    }

    private func musicAmountKey(for control: SceneInspectorEffectControl) -> String {
        "\(overrideKey(for: control) ?? control.id)_musicAmount"
    }

    func resetEffectValue(_ control: SceneInspectorEffectControl) {
        setEffectValue(control.defaultValue, control: control)
    }

    func setEffectEnabled(_ enabled: Bool, effect: SceneInspectorEffect) {
        effectEnabled[effect.id] = enabled
        let parts = effect.id.split(separator: ":")
        guard parts.count == 2, let objectID = Int(parts[0]), let effectIndex = Int(parts[1]) else { return }
        let key = sceneAuthoredEffectEnabledKey(objectID: objectID, effectIndex: effectIndex)
        var values = targets.storedValues
        values[key] = enabled ? "true" : "false"
        persist(values)
    }

    func setObjectVisible(_ visible: Bool, item: SceneInspectorItem) {
        let objectID = Int(item.id) ?? 0
        var values = targets.storedValues
        values[sceneObjectVisibilityKey(objectID: objectID)] = visible ? "true" : "false"
        persist(values)
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = SceneInspectorItem(id: item.id, name: item.name, kind: item.kind,
                                              sourcePath: item.sourcePath, materialPath: item.materialPath,
                                              texturePaths: item.texturePaths, shaderPaths: item.shaderPaths,
                                              rawObject: item.rawObject, rawMaterial: item.rawMaterial,
                                              rawParticle: item.rawParticle, visible: visible,
                                              isVersion: item.isVersion, versionName: item.versionName,
                                              versionValue: item.versionValue, effects: item.effects)
        }
    }

    func origin(for item: SceneInspectorItem) -> SIMD3<Double> {
        guard let index = items.firstIndex(where: { $0.id == item.id }),
              let data = items[index].rawObject.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return SIMD3<Double>(0, 0, 0)
        }
        return Self.parseOrigin(object["origin"]) ?? SIMD3<Double>(0, 0, 0)
    }

    func moveObject(_ item: SceneInspectorItem, deltaX: Double, deltaY: Double) {
        guard let index = items.firstIndex(where: { $0.id == item.id }),
              let data = items[index].rawObject.data(using: .utf8),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let current = Self.parseOrigin(object["origin"]) ?? SIMD3<Double>(0, 0, 0)
        let updated = SIMD3<Double>(current.x + deltaX, current.y + deltaY, current.z)
        setObjectOrigin(item, index: index, object: &object, origin: updated)
    }

    func alignObject(_ item: SceneInspectorItem, horizontal: SceneHorizontalSnap) {
        guard let index = items.firstIndex(where: { $0.id == item.id }),
              let data = items[index].rawObject.data(using: .utf8),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let current = Self.parseOrigin(object["origin"]) ?? SIMD3<Double>(0, 0, 0)
        let size = Self.parseSize(object["size"]) ?? SIMD2<Double>(300, 120)
        let x: Double
        switch horizontal {
        case .left:
            x = size.x / 2
        case .center:
            x = sceneSize.x / 2
        case .right:
            x = sceneSize.x - size.x / 2
        }
        setObjectOrigin(item, index: index, object: &object, origin: SIMD3<Double>(x, current.y, current.z))
    }

    func alignObject(_ item: SceneInspectorItem, vertical: SceneVerticalSnap) {
        guard let index = items.firstIndex(where: { $0.id == item.id }),
              let data = items[index].rawObject.data(using: .utf8),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let current = Self.parseOrigin(object["origin"]) ?? SIMD3<Double>(0, 0, 0)
        let size = Self.parseSize(object["size"]) ?? SIMD2<Double>(300, 120)
        let y: Double
        switch vertical {
        case .top:
            y = sceneSize.y - size.y / 2
        case .center:
            y = sceneSize.y / 2
        case .bottom:
            y = size.y / 2
        }
        setObjectOrigin(item, index: index, object: &object, origin: SIMD3<Double>(current.x, y, current.z))
    }

    private func setObjectOrigin(_ item: SceneInspectorItem, index: Int, object: inout [String: Any], origin updated: SIMD3<Double>) {
        let origin = Self.originString(updated)
        object["origin"] = origin
        items[index].rawObject = prettyJSON(object)
        var values = targets.storedValues
        values["_owe_scene_object_\(item.id)_origin"] = origin
        persist(values)
    }

    func scale(for item: SceneInspectorItem) -> Double {
        guard let index = items.firstIndex(where: { $0.id == item.id }),
              let data = items[index].rawObject.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let parsed = Self.parseOrigin(object["scale"]) else {
            return 1
        }
        return parsed.x == 0 ? 1 : parsed.x
    }

    func setObjectScale(_ item: SceneInspectorItem, scale value: Double) {
        guard let index = items.firstIndex(where: { $0.id == item.id }),
              let data = items[index].rawObject.data(using: .utf8),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let current = Self.parseOrigin(object["scale"]) ?? SIMD3<Double>(1, 1, 1)
        // Scaling uniformly keeps the object's aspect, and the renderer scales each effect's mask
        // with the layer it belongs to, so masks follow along.
        let updated = SIMD3<Double>(value, value, current.z == 0 ? 1 : current.z)
        let scale = Self.originString(updated)
        object["scale"] = scale
        items[index].rawObject = prettyJSON(object)
        var values = targets.storedValues
        values["_owe_scene_object_\(item.id)_scale"] = scale
        persist(values)
    }

    private static func sceneSize(for scene: WEScene) -> SIMD2<Double> {
        if let projection = scene.general.orthogonalprojection {
            return SIMD2<Double>(Double(projection.width), Double(projection.height))
        }
        let bounds = scene.objects.compactMap { object -> SIMD2<Double>? in
            guard let origin = object.origin?.parseVector3(), let size = object.size?.parseVector2() else { return nil }
            return SIMD2<Double>(origin.0 + size.0 / 2, origin.1 + size.1 / 2)
        }
        guard let width = bounds.map(\.x).max(), let height = bounds.map(\.y).max(), width > 0, height > 0 else {
            return SIMD2<Double>(1920, 1080)
        }
        return SIMD2<Double>(width, height)
    }

    private static func rawObject(_ rawObject: String, settingOrigin origin: String) -> String {
        guard let data = rawObject.data(using: .utf8),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return rawObject }
        object["origin"] = origin
          guard let formatted = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return rawObject }
          return String(data: formatted, encoding: .utf8) ?? rawObject
    }

    private static func parseOrigin(_ value: Any?) -> SIMD3<Double>? {
        if let string = value as? String {
            let parts = string.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
            guard parts.count >= 2 else { return nil }
            return SIMD3<Double>(parts[0], parts[1], parts.indices.contains(2) ? parts[2] : 0)
        }
        if let array = value as? [Any] {
            let parts = array.compactMap { ($0 as? NSNumber)?.doubleValue ?? ($0 as? Double) }
            guard parts.count >= 2 else { return nil }
            return SIMD3<Double>(parts[0], parts[1], parts.indices.contains(2) ? parts[2] : 0)
        }
        if let dict = value as? [String: Any] {
            let x = (dict["x"] as? NSNumber)?.doubleValue ?? dict["x"] as? Double
            let y = (dict["y"] as? NSNumber)?.doubleValue ?? dict["y"] as? Double
            let z = (dict["z"] as? NSNumber)?.doubleValue ?? dict["z"] as? Double ?? 0
            if let x, let y { return SIMD3<Double>(x, y, z) }
        }
        return nil
    }

    private static func parseSize(_ value: Any?) -> SIMD2<Double>? {
        if let string = value as? String {
            let parts = string.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
            guard parts.count >= 2 else { return nil }
            return SIMD2<Double>(parts[0], parts[1])
        }
        if let array = value as? [Any] {
            let parts = array.compactMap { ($0 as? NSNumber)?.doubleValue ?? ($0 as? Double) }
            guard parts.count >= 2 else { return nil }
            return SIMD2<Double>(parts[0], parts[1])
        }
        if let dict = value as? [String: Any] {
            let x = (dict["x"] as? NSNumber)?.doubleValue ?? dict["x"] as? Double
            let y = (dict["y"] as? NSNumber)?.doubleValue ?? dict["y"] as? Double
            if let x, let y { return SIMD2<Double>(x, y) }
        }
        return nil
    }

    private static func originString(_ origin: SIMD3<Double>) -> String {
        let components: [Double] = [origin.x, origin.y, origin.z]
        let parts: [String] = components.map { value -> String in
            value.rounded() == value ? String(Int(value)) : String(value)
        }
        return parts.joined(separator: " ")
    }

    /// An image layer's `colorBlendMode` (WE's default 0, Normal).
    func blendMode(for item: SceneInspectorItem) -> Int {
        guard let data = item.rawObject.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 0 } // not an object: Normal
        return (object["colorBlendMode"] as? NSNumber)?.intValue ?? 0
    }

    /// Sets an image layer's `colorBlendMode`, saved with the object's edited JSON.
    func setBlendMode(_ value: Int, for item: SceneInspectorItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }),
              let data = items[index].rawObject.data(using: .utf8),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        object["colorBlendMode"] = value
        saveObjectJSON(prettyJSON(object), item: items[index])
    }

    /// WE's blend modes as its editor lists them (`WEImageBlendModes`), with WE's labels.
    lazy var blendModeCombo: SceneInspectorEffectCombo = {
        let labels = WallpaperEngineLabels.load()
        return SceneInspectorEffectCombo(
            id: "colorBlendMode", effectID: "", combo: "BLENDMODE",
            title: labels.translation("ui_editor_properties_blend_mode") ?? "Blend mode",
            options: SceneEffectParameters.blendModeOptions.map { option in
                (labels.translation(option.label) ?? option.english ?? option.label, option.value,
                 option.group.map { labels.translation($0) ?? Self.groupTitle($0) })
            })
    }()

    func saveObjectJSON(_ text: String, item: SceneInspectorItem) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              JSONSerialization.isValidJSONObject(object) else { return }
        let formatted = prettyJSON(object)
        var values = targets.storedValues
        values["_owe_scene_object_\(item.id)_json"] = formatted
        persist(values)
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index].rawObject = formatted
        }
    }

    func saveAssetJSON(_ text: String, path: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              JSONSerialization.isValidJSONObject(object) else { return }
        var values = targets.storedValues
        values["_owe_scene_asset_\(path)_json"] = prettyJSON(object)
        persist(values)
    }

    func useVersion(_ item: SceneInspectorItem) {
        guard let value = item.versionValue else { return }
        var values = targets.storedValues
        values["version"] = value
        persist(values)
    }

    func loadTextures(for item: SceneInspectorItem) {
        textureLoadGeneration &+= 1
        let generation = textureLoadGeneration
        decodedTextures = []
        decodedMasks = [:]
        decodedItemID = nil
        guard !item.texturePaths.isEmpty else {
            loadingItemID = nil
            decodedItemID = item.id
            return
        }
        loadingItemID = item.id

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let textures = self.decodeTextures(for: item)
            let masks = Dictionary(uniqueKeysWithValues: item.effects.compactMap { effect -> (String, SceneInspectorTexture)? in
                guard let path = effect.maskPath, let texture = self.decodeTexture(path, itemID: effect.id,
                                                                                   materialPath: "materials") else { return nil }
                return (effect.id, texture)
            })
            DispatchQueue.main.async { [weak self] in
                guard let self, self.textureLoadGeneration == generation else { return }
                self.decodedTextures = textures
                self.decodedMasks = masks
                self.decodedItemID = item.id
                self.loadingItemID = nil
            }
        }
    }

    private func decodeTextures(for item: SceneInspectorItem) -> [SceneInspectorTexture] {
        item.texturePaths.compactMap { decodeTexture($0, itemID: item.id, materialPath: item.materialPath) }
    }

    private func decodeTexture(_ textureName: String, itemID: String, materialPath: String?) -> SceneInspectorTexture? {
        let materialDirectory = ((materialPath ?? "") as NSString).deletingLastPathComponent
        let fileName = (textureName as NSString).pathExtension.isEmpty ? "\(textureName).tex" : textureName
        let candidates = ["\(materialDirectory)/\(fileName)", "materials/\(fileName)", fileName]
            .filter { !$0.hasPrefix("/") }
        var visited = Set<String>()
        for path in candidates where visited.insert(path).inserted {
            guard let bytes = data(path) else { continue }
            let parser = TEXParser(data: bytes)
            let image = parser.extractAnimatedImages()?.images.first ?? parser.extractImage() ?? NSImage(data: bytes)
            if let image { return SceneInspectorTexture(id: "\(itemID):\(path)", path: path, image: image) }
        }
        return nil
    }

    private func data(_ path: String) -> Data? {
        package?.extractFile(named: path) ?? (try? Data(contentsOf: directory.appending(path: path)))
    }

    private func prettyJSON(_ json: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func persist(_ values: [String: String]) {
        targets.publish(values)
        pendingSave?.cancel()
        let work = DispatchWorkItem { [targets] in targets.save(values) }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }
}

extension AppDelegate {
    /// `scopes`: whose properties its edits change (`WallpaperViewModel.editedPropertyScopes`).
    func showSceneInspector(for wallpaper: WEWallpaper, scopes: [WallpaperPropertyScope] = [.shared]) {
        if let sceneInspectorWindow {
            sceneInspectorWindow.contentView = NSHostingView(rootView: SceneInspectorView(wallpaper: wallpaper, scopes: scopes))
            sceneInspectorWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Scene Inspector"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SceneInspectorView(wallpaper: wallpaper, scopes: scopes))
        window.center()
        window.makeKeyAndOrderFront(nil)
        sceneInspectorWindow = window
    }
}

struct SceneInspectorView: View {
    @StateObject private var model: SceneInspectorModel
    @State private var selectedID: String?
    @State private var searchText = ""
    @State private var didCopyPath = false
    @FocusState private var isSearchFocused: Bool
    private let wallpaperDirectory: URL

    init(wallpaper: WEWallpaper, scopes: [WallpaperPropertyScope] = [.shared]) {
        wallpaperDirectory = wallpaper.wallpaperDirectory
        _model = StateObject(wrappedValue: SceneInspectorModel(wallpaper: wallpaper, scopes: scopes))
    }

    private func matches(_ item: SceneInspectorItem) -> Bool {
        guard !searchText.isEmpty else { return true }
        if item.name.localizedCaseInsensitiveContains(searchText)
            || item.kind.localizedCaseInsensitiveContains(searchText)
            || item.sourcePath.localizedCaseInsensitiveContains(searchText)
            || (item.materialPath?.localizedCaseInsensitiveContains(searchText) ?? false)
            || (item.versionName?.localizedCaseInsensitiveContains(searchText) ?? false) {
            return true
        }
        if item.texturePaths.contains(where: { $0.localizedCaseInsensitiveContains(searchText) })
            || item.shaderPaths.contains(where: { $0.localizedCaseInsensitiveContains(searchText) }) {
            return true
        }
        return item.effects.contains { effect in
            effect.name.localizedCaseInsensitiveContains(searchText)
                || effect.title.localizedCaseInsensitiveContains(searchText)
                || (effect.maskPath?.localizedCaseInsensitiveContains(searchText) ?? false)
                || effect.controls.contains { $0.title.localizedCaseInsensitiveContains(searchText) || $0.key.localizedCaseInsensitiveContains(searchText) }
        }
    }

    var body: some View {
        inspectorSplitView
            .frame(minWidth: 1120, minHeight: 560)
            .onAppear {
                selectedID = model.initiallySelectedID
                loadSelectedTextures()
            }
            .onChange(of: selectedID) { _, _ in loadSelectedTextures() }
    }

    /// Both side columns (the object list and the movement controls) share one width.
    private static let sidebarWidth: CGFloat = 300

    private var inspectorSplitView: some View {
        HSplitView {
            sidebarColumn
                .frame(width: Self.sidebarWidth)
            detailColumn
                .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                searchField
            }
            ToolbarItem(placement: .primaryAction) {
                pathControl
            }
        }
        .background {
            Button("") { isSearchFocused = true }
                .keyboardShortcut("k", modifiers: .command)
                .hidden()
        }
    }

    private var sidebarColumn: some View {
        List(selection: $selectedID) {
            let versions = model.items.filter(\.isVersion).filter(matches)
            if !versions.isEmpty {
                Section("Versions") {
                    ForEach(versions) { item in
                        Label(item.versionName ?? item.name, systemImage: "square.stack.3d.up")
                            .tag(item.id)
                    }
                }
            }
            Section("Scene Objects") {
                ForEach(model.items.filter { !$0.isVersion }.filter(matches)) { item in
                    HStack(spacing: 8) {
                        Label(item.name, systemImage: item.kind == "Particle" ? "sparkles" : "photo")
                        Spacer(minLength: 4)
                        Toggle("", isOn: Binding(
                            get: { item.visible },
                            set: { model.setObjectVisible($0, item: item) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .help(item.visible ? "Hide object" : "Show object")
                    }
                    .contentShape(Rectangle())
                    .tag(item.id)
                }
            }
        }
        .navigationTitle("Scene Inspector")
    }

    private var detailColumn: some View {
        let selectedItem = model.items.first(where: { $0.id == selectedID })
        return HStack(spacing: 0) {
            Group {
                if let item = selectedItem {
                    selectedItemDetail(item)
                } else if let error = model.errorMessage {
                    ContentUnavailableView("Scene Unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    ContentUnavailableView("Select a Scene Object", systemImage: "square.stack.3d.up")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            movementColumn(for: selectedItem)
        }
        .focusable()
        .onMoveCommand { direction in
            if let selectedItem { move(selectedItem, direction: direction) }
        }
    }

    /// Styled after the Apple Music search field: a soft filled capsule that brightens and picks up
    /// an accent ring while focused.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSearchFocused ? Color.accentColor : .secondary)
            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isSearchFocused)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 9)
        .frame(width: isSearchFocused ? 300 : 240, height: 24)
        .background {
            Capsule()
                .fill(Color.primary.opacity(isSearchFocused ? 0.10 : 0.06))
        }
        .overlay {
            Capsule()
                .strokeBorder(Color.accentColor.opacity(isSearchFocused ? 0.55 : 0), lineWidth: 1)
        }
        .animation(.easeOut(duration: 0.18), value: isSearchFocused)
        .animation(.easeOut(duration: 0.12), value: searchText.isEmpty)
        .contentShape(Capsule())
        .onTapGesture { isSearchFocused = true }
    }

    /// Shows where the wallpaper lives and copies that path, so its files can be opened elsewhere.
    private var pathControl: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(wallpaperDirectory.path, forType: .string)
            didCopyPath = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { didCopyPath = false }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: didCopyPath ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12))
                Text(didCopyPath ? "Copied" : "Copy Path")
                    .font(.system(size: 12))
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .frame(minHeight: 24)
            .background {
                Capsule().fill(Color.primary.opacity(0.06))
            }
        }
        .buttonStyle(.plain)
        .help(didCopyPath ? "Copied" : "Copy wallpaper folder path\n\(wallpaperDirectory.path)")
    }

    private func selectedItemDetail(_ item: SceneInspectorItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                LabeledContent("Type", value: item.kind)
                if item.isVersion {
                    Button {
                        model.useVersion(item)
                    } label: {
                        Label("Use This Version", systemImage: "checkmark.circle")
                    }
                }
                if !item.sourcePath.isEmpty { LabeledContent("Source", value: item.sourcePath) }
                if let material = item.materialPath { LabeledContent("Material", value: material) }
                detailList("Textures", values: item.texturePaths)
                decodedTextureList(for: item)
                detailList("Shaders", values: item.shaderPaths)
                effectList(for: item)
                editableObjectBlock(for: item)
                if let particle = item.rawParticle {
                    editableAssetBlock(title: "Particle System", text: particle, path: item.sourcePath)
                }
                if let material = item.rawMaterial, let materialPath = item.materialPath {
                    editableAssetBlock(title: "Material Properties", text: material, path: materialPath)
                }
            }
            .padding()
        }
        .navigationTitle(item.name)
    }

    @ViewBuilder private func effectList(for item: SceneInspectorItem) -> some View {
        if !item.effects.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Effects").font(.title3.bold())
                ForEach(item.effects) { effect in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 10) {
                            if let maskPath = effect.maskPath {
                                HStack(spacing: 5) {
                                    Text("Mask").font(.headline)
                                    InfoTip("Limits this effect to the white areas of the mask. Black areas are left untouched.")
                                }
                                Text(maskPath).font(.caption.monospaced()).foregroundStyle(.secondary)
                                if let mask = model.decodedMasks[effect.id] {
                                    Image(nsImage: mask.image)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(maxWidth: .infinity, maxHeight: 300)
                                        .background(Color.black)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                } else if model.loadingItemID == item.id {
                                    ProgressView()
                                }
                            } else {
                                Text("No mask").font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(effect.combos.filter { model.requirementsHold($0, in: effect) }) { combo in
                                effectComboControl(combo, effect: effect)
                            }
                            ForEach(effect.controls) { control in
                                if control.isColor {
                                    if control.component == 0 {
                                        ColorPicker(selection: Binding(
                                            get: { model.effectColor(for: control) },
                                            set: { model.setEffectColor($0, control: control) }
                                        ), supportsOpacity: false) {
                                            parameterLabel(control.title, help: parameterHelp(control, effect: effect.name))
                                        }
                                        .anchorsColorPanel()
                                    }
                                } else {
                                    effectSlider(control, effect: effect)
                                }
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        HStack {
                            Toggle("", isOn: Binding(
                                get: { model.effectEnabled[effect.id] ?? true },
                                set: { model.setEffectEnabled($0, effect: effect) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                            Label(effect.title, systemImage: "slider.horizontal.3")
                            InfoTip(SceneHelp.effect(effect.name))
                        }
                    }
                }
            }
        }
    }

    /// WE's material slider: the annotation's range, step 0.01 (1 for `int`), and a number field
    /// that accepts values past the range.
    @ViewBuilder private func effectSlider(_ control: SceneInspectorEffectControl, effect: SceneInspectorEffect) -> some View {
        let value = Binding<Double>(
            get: { model.displayedEffectValue(for: control) },
            set: { model.setDisplayedEffectValue($0, control: control) }
        )
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                parameterLabel(control.title, help: parameterHelp(control, effect: effect.name))
                if control.isLinked, control.component == 0 {
                    Toggle(isOn: Binding(get: { model.isLinked(control) },
                                         set: { model.setLinked($0, control: control) })) {
                        Image(systemName: "link")
                    }
                    .toggleStyle(.button)
                    .help("Edit X and Y together")
                }
            }
            NumericSliderInput(value: value,
                               range: control.minimum...max(control.maximum, control.minimum + 0.001),
                               defaultValue: control.defaultValue,
                               step: control.isInteger ? 1 : 0.01,
                               fractionDigits: control.isInteger ? 0 : 2, fieldWidth: 76,
                               clampsTypedValue: false)
            inspectorMusicSyncControls(for: control)
        }
    }

    @ViewBuilder private func effectComboControl(_ combo: SceneInspectorEffectCombo, effect: SceneInspectorEffect) -> some View {
        let selection = Binding<Int>(get: { model.comboValue(combo) }, set: { model.setComboValue($0, combo: combo) })
        if combo.options.isEmpty {
            Toggle(combo.title, isOn: Binding(get: { selection.wrappedValue != 0 },
                                              set: { selection.wrappedValue = $0 ? 1 : 0 }))
                .toggleStyle(.checkbox)
        } else {
            Picker(combo.title, selection: selection) {
                ForEach(Self.optionGroups(combo), id: \.offset) { group in
                    if let heading = group.heading {
                        Section(heading) {
                            ForEach(group.options, id: \.value) { option in Text(option.title).tag(option.value) }
                        }
                    } else {
                        ForEach(group.options, id: \.value) { option in Text(option.title).tag(option.value) }
                    }
                }
            }
        }
    }

    /// The combo's options in runs of one editor group (WE's "Native (fast)" / "Emulated (slow)"
    /// blend modes), in order; one run without a heading for authored options.
    private static func optionGroups(_ combo: SceneInspectorEffectCombo)
        -> [(offset: Int, heading: String?, options: [(title: String, value: Int)])] {
        var groups: [(offset: Int, heading: String?, options: [(title: String, value: Int)])] = []
        for option in combo.options {
            if groups.isEmpty || groups[groups.count - 1].heading != option.group {
                groups.append((groups.count, option.group, []))
            }
            groups[groups.count - 1].options.append((option.title, option.value))
        }
        return groups
    }

    @ViewBuilder private func inspectorMusicSyncControls(for control: SceneInspectorEffectControl) -> some View {
        let isEnabled = Binding<Bool>(
            get: { model.musicSyncEnabled(for: control) },
            set: { model.setMusicSyncEnabled($0, for: control) }
        )
        Toggle("Sync to Music", isOn: isEnabled)
            .toggleStyle(.checkbox)
            .font(.caption)
            .help(SceneHelp.musicSyncSource)
        if isEnabled.wrappedValue {
            let span = max(control.maximum - control.minimum, 0.001)
            let amount = Binding<Double>(
                get: { model.musicAmount(for: control) },
                set: { model.setMusicAmount($0, for: control) }
            )
            HStack {
                Text("Music Amount")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                NumericSliderInput(value: amount, range: -span...span,
                                   defaultValue: 0, fractionDigits: 3,
                                   sliderWidth: 100, fieldWidth: 64)
            }
        }
    }

    @ViewBuilder private func movementControls(for item: SceneInspectorItem?) -> some View {
        let origin = item.map(model.origin(for:))
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Move Element", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.title3.bold())
                Spacer()
                if let origin {
                    Text("X \(Int(origin.x))  Y \(Int(origin.y))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Color.clear.frame(width: 48, height: 40)
                    moveButton(systemImage: "arrow.up", help: "Move up") {
                        guard let item else { return }
                        model.moveObject(item, deltaX: 0, deltaY: movementStep())
                    }
                    Color.clear.frame(width: 48, height: 40)
                }
                GridRow {
                    moveButton(systemImage: "arrow.left", help: "Move left") {
                        guard let item else { return }
                        model.moveObject(item, deltaX: -movementStep(), deltaY: 0)
                    }
                    Text("Move")
                        .font(.callout.weight(.semibold))
                        .frame(width: 58, height: 40)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    moveButton(systemImage: "arrow.right", help: "Move right") {
                        guard let item else { return }
                        model.moveObject(item, deltaX: movementStep(), deltaY: 0)
                    }
                }
                GridRow {
                    Color.clear.frame(width: 48, height: 40)
                    moveButton(systemImage: "arrow.down", help: "Move down") {
                        guard let item else { return }
                        model.moveObject(item, deltaX: 0, deltaY: -movementStep())
                    }
                    Color.clear.frame(width: 48, height: 40)
                }
            }
            .disabled(item == nil)
            .opacity(item == nil ? 0.4 : 1)
            Text(item == nil ? "Select an object to move it." : "Arrow keys work when this panel is focused. Shift moves faster, Control moves slower.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor.opacity(0.45), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func moveButton(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .frame(width: 48, height: 40)
        }
        .buttonStyle(.borderedProminent)
        .help("\(help). Shift = 50 px, Control = 1 px, default = 10 px")
    }

    @ViewBuilder private func scaleControls(for item: SceneInspectorItem?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Size", systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.headline)
                Spacer()
                if let item {
                    Text(String(format: "%.2f×", model.scale(for: item)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let item {
                let binding = Binding(
                    get: { model.scale(for: item) },
                    set: { model.setObjectScale(item, scale: $0) })
                NumericSliderInput(value: binding, range: 0.05...5,
                                   defaultValue: 1, step: 0.05, suffix: "x",
                                   fractionDigits: 2, sliderWidth: 120, fieldWidth: 52)
                Button("Reset to 1x") { model.setObjectScale(item, scale: 1) }
                    .buttonStyle(.link)
                    .font(.caption)
                if item.kind == "Image" {
                    blendModePicker(for: item)
                }
            } else {
                Text("Select an object to resize it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The image layer's blend mode, WE's 33 in its editor's order and groups.
    private func blendModePicker(for item: SceneInspectorItem) -> some View {
        let combo = model.blendModeCombo
        return Picker(combo.title, selection: Binding(get: { model.blendMode(for: item) },
                                                      set: { model.setBlendMode($0, for: item) })) {
            ForEach(Self.optionGroups(combo), id: \.offset) { group in
                Section(group.heading ?? "") {
                    ForEach(group.options, id: \.value) { option in Text(option.title).tag(option.value) }
                }
            }
        }
    }

    private func movementColumn(for item: SceneInspectorItem?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            movementControls(for: item)
            Divider()
            scaleControls(for: item)
            Divider()
            alignmentControls(for: item)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Step")
                    .font(.headline)
                Text("Default 10 px")
                Text("Shift 50 px")
                Text("Control 1 px")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(14)
        .frame(width: Self.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func alignmentControls(for item: SceneInspectorItem?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Align Element", systemImage: "align.horizontal.center")
                .font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                Text("Horizontal")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    alignmentButton("Left", systemImage: "align.horizontal.left") {
                        guard let item else { return }
                        model.alignObject(item, horizontal: .left)
                    }
                    alignmentButton("Center", systemImage: "align.horizontal.center") {
                        guard let item else { return }
                        model.alignObject(item, horizontal: .center)
                    }
                    alignmentButton("Right", systemImage: "align.horizontal.right") {
                        guard let item else { return }
                        model.alignObject(item, horizontal: .right)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Vertical")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    alignmentButton("Top", systemImage: "align.vertical.top") {
                        guard let item else { return }
                        model.alignObject(item, vertical: .top)
                    }
                    alignmentButton("Center", systemImage: "align.vertical.center") {
                        guard let item else { return }
                        model.alignObject(item, vertical: .center)
                    }
                    alignmentButton("Bottom", systemImage: "align.vertical.bottom") {
                        guard let item else { return }
                        model.alignObject(item, vertical: .bottom)
                    }
                }
            }
        }
        .disabled(item == nil)
        .opacity(item == nil ? 0.4 : 1)
    }

    private func alignmentButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.callout.weight(.semibold))
                Text(title)
                    .font(.caption2)
            }
            .frame(width: 68, height: 46)
        }
        .buttonStyle(.bordered)
        .help("Align \(title.lowercased())")
    }

    private func move(_ item: SceneInspectorItem, direction: MoveCommandDirection) {
        let step = movementStep()
        switch direction {
        case .up:
            model.moveObject(item, deltaX: 0, deltaY: step)
        case .down:
            model.moveObject(item, deltaX: 0, deltaY: -step)
        case .left:
            model.moveObject(item, deltaX: -step, deltaY: 0)
        case .right:
            model.moveObject(item, deltaX: step, deltaY: 0)
        @unknown default:
            break
        }
    }

    private func movementStep() -> Double {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift) { return 50 }
        if flags.contains(.control) { return 1 }
        return 10
    }

    private func parameterLabel(_ title: String, help: String) -> some View {
        HStack(spacing: 5) {
            Text(title)
            InfoTip(help)
        }
    }

    private func parameterHelp(_ control: SceneInspectorEffectControl, effect: String? = nil) -> String {
        SceneHelp.parameter(effect: effect, key: control.key, title: control.title,
                            displaysDegrees: control.displaysDegrees)
    }


    @ViewBuilder private func decodedTextureList(for item: SceneInspectorItem) -> some View {
        if model.loadingItemID == item.id {
            ProgressView("Decoding textures...")
        } else if model.decodedItemID == item.id {
            ForEach(model.decodedTextures) { texture in
                VStack(alignment: .leading, spacing: 6) {
                    Text(texture.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Image(nsImage: texture.image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: 420)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            if !item.texturePaths.isEmpty && model.decodedTextures.isEmpty {
                ContentUnavailableView("Texture Unavailable", systemImage: "photo.badge.exclamationmark")
            }
        }
    }

    private func loadSelectedTextures() {
        guard let item = model.items.first(where: { $0.id == selectedID }) else { return }
        model.loadTextures(for: item)
    }

    @ViewBuilder private func detailList(_ title: String, values: [String]) -> some View {
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                ForEach(values, id: \.self) { Text($0).font(.caption.monospaced()) }
            }
        }
    }

    private func sourceBlock(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(text).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                .padding(8).background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    @ViewBuilder private func editableAssetBlock(title: String, text: String, path: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Save") {
                    model.saveAssetJSON(text, path: path)
                }
                .buttonStyle(.borderedProminent)
            }
            TextEditor(text: Binding(
                get: { text },
                set: { value in
                    if let itemIndex = model.items.firstIndex(where: { $0.id == selectedID }) {
                        if title == "Particle System" {
                            model.items[itemIndex].rawParticle = value
                        } else {
                            model.items[itemIndex].rawMaterial = value
                        }
                    }
                }
            ))
            .font(.system(.caption, design: .monospaced))
            .frame(minHeight: 220)
            .padding(6)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    @ViewBuilder private func editableObjectBlock(for item: SceneInspectorItem) -> some View {
        if item.isSynthetic {
            VStack(alignment: .leading, spacing: 6) {
                Text("Layer Details").font(.headline)
                Text(model.items.first(where: { $0.id == item.id })?.rawObject ?? item.rawObject)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Object Properties").font(.headline)
                    Spacer()
                    Button("Save") {
                        let current = model.items.first(where: { $0.id == item.id })?.rawObject ?? item.rawObject
                        model.saveObjectJSON(current, item: item)
                    }
                    .buttonStyle(.borderedProminent)
                }
                TextEditor(text: Binding(
                    get: { model.items.first(where: { $0.id == item.id })?.rawObject ?? item.rawObject },
                    set: { value in
                        guard let index = model.items.firstIndex(where: { $0.id == item.id }) else { return }
                        model.items[index].rawObject = value
                    }
                ))
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 220)
                .padding(6)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}