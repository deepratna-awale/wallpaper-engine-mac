import SwiftUI

private struct SceneUserProperty: Identifiable {
    let id: String
    let title: String
    let type: String
    let order: Int
    let defaultValue: String
    let options: [(title: String, value: String)]
    let minimum: Double
    let maximum: Double
}

private struct SceneTextControl: Identifiable {
    let id: String
    let title: String
    let font: String
    let size: Double
}

private final class SceneUserPropertiesModel: ObservableObject {
    @Published var properties: [SceneUserProperty] = []
    @Published var values: [String: String] = [:]
    @Published var textObjects: [SceneTextControl] = []
    private let storageKey: String
    private let explicitKey: String

    init(wallpaper: WEWallpaper) {
        storageKey = "SceneUserProperties.\(wallpaper.wallpaperDirectory.path)"
        explicitKey = "SceneUserPropertiesExplicit.\(wallpaper.wallpaperDirectory.path)"
        load(wallpaper)
    }

    func set(_ value: String, for property: SceneUserProperty) {
        values[property.id] = value
        UserDefaults.standard.set(values, forKey: storageKey)
        UserDefaults.standard.set(true, forKey: explicitKey)
        AudioReactiveScriptEngine.shared.setUserProperties(values)
    }

    private func load(_ wallpaper: WEWallpaper) {
          guard let data = try? Data(contentsOf: wallpaper.wallpaperDirectory.appending(path: "project.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
          let rawProperties = ((root["general"] as? [String: Any])?["properties"] as? [String: [String: Any]]) ?? [:]
        properties = rawProperties.compactMap { (key: String, raw: [String: Any]) -> SceneUserProperty? in
            guard let title = raw["text"] as? String, let type = raw["type"] as? String else { return nil }
            let options = (raw["options"] as? [[String: Any]] ?? []).compactMap { option -> (String, String)? in
                guard let label = option["label"] as? String, let optionValue = option["value"] else { return nil }
                return (label, sceneUserPropertyString(optionValue))
            }
            let defaultValue = raw["value"].map(sceneUserPropertyString)
                ?? (type == "combo" ? options.first?.1 : nil)
                ?? (type == "bool" ? "false" : "")
            return SceneUserProperty(id: key, title: title, type: type,
                                     order: (raw["order"] as? NSNumber)?.intValue ?? Int.max,
                                     defaultValue: defaultValue, options: options,
                                     minimum: (raw["min"] as? NSNumber)?.doubleValue ?? 0,
                                     maximum: (raw["max"] as? NSNumber)?.doubleValue ?? 1)
        }
        .sorted { ($0.order, $0.id) < ($1.order, $1.id) }
        if wallpaper.project.type.lowercased() == "scene" {
            let authoredEffects = authoredEffectNames(for: wallpaper)
            let effectNames = ["shake", "waterwaves", "nitro", "vhs", "pulse", "iris", "volumetricfog", "parallax"]
            properties.append(contentsOf: [
                SceneUserProperty(id: "_owe_hue", title: "Hue", type: "slider", order: Int.max - 5, defaultValue: "0", options: [], minimum: -Double.pi, maximum: Double.pi),
                SceneUserProperty(id: "_owe_saturation", title: "Saturation", type: "slider", order: Int.max - 4, defaultValue: "1", options: [], minimum: 0, maximum: 2),
                SceneUserProperty(id: "_owe_bloom", title: "Bloom", type: "slider", order: Int.max - 3, defaultValue: "1", options: [], minimum: 0, maximum: 2),
                SceneUserProperty(id: "_owe_blur", title: "Blur", type: "slider", order: Int.max - 2, defaultValue: "1", options: [], minimum: 0, maximum: 2),
                SceneUserProperty(id: "_owe_speed", title: "Animation Speed", type: "slider", order: Int.max - 1, defaultValue: "1", options: [], minimum: 0, maximum: 2),
                SceneUserProperty(id: "_owe_effect_shake_strength", title: "Shake Strength", type: "slider", order: Int.max - 10, defaultValue: "0.072", options: [], minimum: 0, maximum: 1),
                SceneUserProperty(id: "_owe_effect_shake_speed", title: "Shake Speed", type: "slider", order: Int.max - 11, defaultValue: "2", options: [], minimum: 0, maximum: 10),
                SceneUserProperty(id: "_owe_effect_shake_friction", title: "Shake Friction", type: "slider", order: Int.max - 12, defaultValue: "1", options: [], minimum: 0, maximum: 10),
                SceneUserProperty(id: "_owe_effect_waterwaves_strength", title: "Water Waves Strength", type: "slider", order: Int.max - 9, defaultValue: "0.03", options: [], minimum: 0, maximum: 1),
                SceneUserProperty(id: "_owe_effect_waterwaves_speed", title: "Water Waves Speed", type: "slider", order: Int.max - 13, defaultValue: "3", options: [], minimum: 0, maximum: 50),
                SceneUserProperty(id: "_owe_effect_waterwaves_scale", title: "Water Waves Scale", type: "slider", order: Int.max - 8, defaultValue: "25", options: [], minimum: 1, maximum: 100),
                SceneUserProperty(id: "_owe_effect_waterwaves_exponent", title: "Water Waves Exponent", type: "slider", order: Int.max - 14, defaultValue: "1", options: [], minimum: 0.5, maximum: 4),
                SceneUserProperty(id: "_owe_effect_waterwaves_direction", title: "Water Waves Direction", type: "slider", order: Int.max - 15, defaultValue: "0", options: [], minimum: -Double.pi, maximum: Double.pi),
                SceneUserProperty(id: "_owe_effect_nitro_multiply", title: "Nitro Intensity", type: "slider", order: Int.max - 7, defaultValue: "0.75", options: [], minimum: 0, maximum: 2),
                SceneUserProperty(id: "_owe_effect_vhs_strength", title: "VHS Strength", type: "slider", order: Int.max - 6, defaultValue: "1.2", options: [], minimum: 0, maximum: 2),
                SceneUserProperty(id: "_owe_effect_vhs_chromatic", title: "VHS Chromatic", type: "slider", order: Int.max - 5, defaultValue: "0.1", options: [], minimum: 0, maximum: 1),
                SceneUserProperty(id: "_owe_effect_vhs_artifacts", title: "VHS Artifacts", type: "slider", order: Int.max - 4, defaultValue: "0.5", options: [], minimum: 0, maximum: 1),
                SceneUserProperty(id: "_owe_effect_vhs_distortionstrength", title: "VHS Distortion", type: "slider", order: Int.max - 16, defaultValue: "1", options: [], minimum: 0, maximum: 2),
                SceneUserProperty(id: "_owe_effect_vhs_distortionspeed", title: "VHS Distortion Speed", type: "slider", order: Int.max - 17, defaultValue: "1", options: [], minimum: 0, maximum: 2),
                SceneUserProperty(id: "_owe_effect_vhs_distortionwidth", title: "VHS Distortion Width", type: "slider", order: Int.max - 18, defaultValue: "1", options: [], minimum: 0, maximum: 2),
                SceneUserProperty(id: "_owe_effect_volumetricfog_density", title: "Fog Density", type: "slider", order: Int.max - 19, defaultValue: "0.65", options: [], minimum: 0, maximum: 2),
                SceneUserProperty(id: "_owe_effect_volumetricfog_drift", title: "Fog Drift", type: "slider", order: Int.max - 20, defaultValue: "0.035", options: [], minimum: 0, maximum: 1),
                SceneUserProperty(id: "_owe_effect_volumetricfog_near", title: "Fog Near", type: "slider", order: Int.max - 21, defaultValue: "0.45", options: [], minimum: 0, maximum: 1),
                SceneUserProperty(id: "_owe_effect_volumetricfog_far", title: "Fog Far", type: "slider", order: Int.max - 22, defaultValue: "0.85", options: [], minimum: 0, maximum: 1)
            ])
            properties.append(contentsOf: effectNames.enumerated().map { index, name in
                SceneUserProperty(id: "_owe_effect_enabled_\(name)", title: name.capitalized, type: "bool",
                                  order: Int.max - 30 + index, defaultValue: authoredEffects.contains(name) ? "true" : "false",
                                  options: [], minimum: 0, maximum: 1)
            })
            let textLayers = textObjectsInScene(for: wallpaper)
            textObjects = textLayers
            for (index, textLayer) in textLayers.enumerated() {
                let prefix = "_owe_text_\(textLayer.id)_"
                properties.append(contentsOf: [
                    SceneUserProperty(id: prefix + "enabled", title: "Enabled", type: "bool", order: Int.max - 110 + index, defaultValue: "true", options: [], minimum: 0, maximum: 1),
                    SceneUserProperty(id: prefix + "font", title: "Font", type: "textinput", order: Int.max - 100 + index, defaultValue: textLayer.font, options: [], minimum: 0, maximum: 1),
                    SceneUserProperty(id: prefix + "size", title: "Font Size", type: "slider", order: Int.max - 90 + index, defaultValue: String(textLayer.size), options: [], minimum: 1, maximum: 256),
                    SceneUserProperty(id: prefix + "bold", title: "Bold", type: "bool", order: Int.max - 80 + index, defaultValue: "false", options: [], minimum: 0, maximum: 1),
                    SceneUserProperty(id: prefix + "italic", title: "Italic", type: "bool", order: Int.max - 70 + index, defaultValue: "false", options: [], minimum: 0, maximum: 1),
                    SceneUserProperty(id: prefix + "color", title: "Color", type: "color", order: Int.max - 60 + index, defaultValue: "1 1 1", options: [], minimum: 0, maximum: 1),
                    SceneUserProperty(id: prefix + "opacity", title: "Transparency", type: "slider", order: Int.max - 50 + index, defaultValue: "1", options: [], minimum: 0, maximum: 1)
                ])
            }
        }
        values = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String] ?? [:]
        for property in properties where values[property.id] == nil {
            values[property.id] = property.defaultValue
        }
        AudioReactiveScriptEngine.shared.setUserProperties(values)
    }

    private func authoredEffectNames(for wallpaper: WEWallpaper) -> Set<String> {
        let sceneFile = wallpaper.project.file
        let packageURL = wallpaper.wallpaperDirectory.appending(path: (sceneFile as NSString).deletingPathExtension + ".pkg")
        guard let package = try? PKGParser(url: packageURL),
              let scene = try? package.extractJSON(named: sceneFile, as: WEScene.self) else { return [] }
        var names = Set((scene.effects ?? []).map { $0.lowercased() })
        for object in scene.objects {
            if let depth = object.parallaxDepth?.parseVector3(), depth.0 != 0 || depth.1 != 0 || depth.2 != 0 || object.perspective == true {
                names.insert("parallax")
            }
            for effect in object.effects ?? [] {
                names.insert(((effect.file as NSString).deletingLastPathComponent as NSString).lastPathComponent.lowercased())
            }
        }
        return names
    }

    private func textObjectsInScene(for wallpaper: WEWallpaper) -> [SceneTextControl] {
        let sceneFile = wallpaper.project.file
        let packageURL = wallpaper.wallpaperDirectory.appending(path: (sceneFile as NSString).deletingPathExtension + ".pkg")
        guard let package = try? PKGParser(url: packageURL),
              let scene = try? package.extractJSON(named: sceneFile, as: WEScene.self) else { return [] }
        return scene.objects.enumerated().compactMap { index, object in
            guard object.textValue != nil else { return nil }
            return SceneTextControl(id: String(object.id ?? index), title: object.name?.isEmpty == false ? object.name! : "Text \(index + 1)",
                                    font: object.font ?? "", size: object.pointsize ?? 24)
        }
    }
}

struct SceneUserPropertiesView: View {
    @StateObject private var model: SceneUserPropertiesModel

    init(wallpaper: WEWallpaper) {
        _model = StateObject(wrappedValue: SceneUserPropertiesModel(wallpaper: wallpaper))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(model.properties.filter { !isEffectProperty($0) }) { property in
                if !isTextProperty(property) {
                    propertyView(property)
                }
            }
            if !model.properties.filter(isEffectProperty).isEmpty {
                DisclosureGroup("Effects") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(effectNames, id: \.self) { effectName in
                            effectGroup(effectName)
                        }
                    }
                    .padding(.top, 6)
                }
            }
            if !model.textObjects.isEmpty {
                DisclosureGroup("Text") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(model.textObjects, id: \.id) { textObject in
                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(model.properties.filter { $0.id.hasPrefix("_owe_text_\(textObject.id)_") }) { property in
                                        propertyView(property)
                                    }
                                }
                                .padding(.top, 4)
                            } label: {
                                HStack {
                                    if let enabled = model.properties.first(where: { $0.id == "_owe_text_\(textObject.id)_enabled" }) {
                                        propertyView(enabled)
                                    }
                                    Text(textObject.title)
                                    Spacer()
                                }
                            }
                        }
                    }
                    .padding(.top, 6)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func isEffectProperty(_ property: SceneUserProperty) -> Bool {
        property.id == "vhs" || property.id == "eyenitro" || property.id.hasPrefix("_owe_effect_")
    }

    private func isTextProperty(_ property: SceneUserProperty) -> Bool {
        property.id.hasPrefix("_owe_text_")
    }

    private var effectNames: [String] {
        ["shake", "waterwaves", "nitro", "vhs", "pulse", "iris", "volumetricfog", "parallax"]
    }

    @ViewBuilder
    private func effectGroup(_ name: String) -> some View {
        let enabledID = "_owe_effect_enabled_\(name)"
        let controls = model.properties.filter { property in
            property.id == enabledID || property.id.hasPrefix("_owe_effect_\(name)_")
                || (name == "vhs" && property.id == "vhs")
                || (name == "nitro" && property.id == "eyenitro")
        }
        if !controls.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(controls.filter { $0.id != enabledID && $0.id != name && $0.id != "vhs" && $0.id != "eyenitro" }) { property in
                        propertyView(property)
                    }
                }
                .padding(.top, 4)
            } label: {
                HStack {
                    if let enabled = controls.first(where: { $0.id == enabledID }) {
                        propertyView(enabled)
                    } else if let authored = controls.first(where: { $0.id == name || (name == "nitro" && $0.id == "eyenitro") }) {
                        propertyView(authored)
                    } else {
                        Text(name.capitalized)
                    }
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private func propertyView(_ property: SceneUserProperty) -> some View {
            switch property.type {
            case "group":
                HStack(spacing: 6) {
                    Text(property.title).font(.headline)
                    Divider()
                }
            case "slider":
                let value = Binding<Double>(get: { Double(model.values[property.id] ?? property.defaultValue) ?? property.minimum },
                                            set: { model.set(String($0), for: property) })
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Text(property.title); Spacer(); Text(String(format: "%.2f", value.wrappedValue)).foregroundStyle(.secondary) }
                    Slider(value: value, in: property.minimum...max(property.maximum, property.minimum + 0.001))
                }
            case "bool":
                Toggle(property.title, isOn: Binding(get: { (model.values[property.id] ?? property.defaultValue).lowercased() == "true" },
                                                      set: { model.set($0 ? "true" : "false", for: property) }))
                    .toggleStyle(.checkbox)
            case "combo":
                Picker(property.title, selection: Binding(get: { model.values[property.id] ?? property.defaultValue },
                                                          set: { model.set($0, for: property) })) {
                    ForEach(property.options, id: \.value) { option in Text(option.title).tag(option.value) }
                }
            case "textinput":
                TextField(property.title, text: Binding(get: { model.values[property.id] ?? property.defaultValue },
                                                        set: { model.set($0, for: property) }))
            case "color":
                TextField(property.title, text: Binding(get: { model.values[property.id] ?? property.defaultValue },
                                                        set: { model.set($0, for: property) }))
                    .textFieldStyle(.roundedBorder)
            default:
                EmptyView()
            }
    }
}