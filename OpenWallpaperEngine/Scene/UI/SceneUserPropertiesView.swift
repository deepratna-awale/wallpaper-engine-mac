import SwiftUI
import UniformTypeIdentifiers

/// Wallpaper Engine authors often put a localization key in a property's `text` field rather than
/// a label. The translations live inside Wallpaper Engine's compiled binaries, so the key is turned
/// into readable words here instead of being shown raw.
private func sceneUserPropertyTitle(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    // Authors write these keys inconsistently — ui_browse_ vs ui_browser_, property vs properties,
    // and stray hyphens — so the prefix is matched loosely rather than from a fixed list.
    guard let range = trimmed.range(of: #"(?i)^ui[_-][a-z]+[_-]propert(y|ies)[_-]"#,
                                    options: .regularExpression) else { return trimmed }
    let stripped = trimmed[range.upperBound...].replacingOccurrences(of: "-", with: "_")
    // Spelled as scheme_color, schemecolor and scheme_-color in the wild; all mean the same thing.
    if stripped.replacingOccurrences(of: "_", with: "").lowercased().hasPrefix("schemecolor") {
        return "Scheme"
    }
    let words = stripped.split(separator: "_").filter { !$0.isEmpty }.map { word -> String in
        word.count <= 2 ? word.uppercased() : word.prefix(1).uppercased() + word.dropFirst()
    }
    return words.isEmpty ? trimmed : words.joined(separator: " ")
}

private struct SceneUserProperty: Identifiable {
    let id: String
    let title: String
    let type: String
    let order: Int
    let defaultValue: String
    let options: [(title: String, value: String)]
    let minimum: Double
    let maximum: Double
    /// project.json `condition`; nil when always shown.
    var condition: UserPropertyCondition? = nil
    /// Raw (possibly HTML) label, kept for `text`/untyped notice rows.
    var rawText: String = ""
    var fraction: Bool = true
    var step: Double? = nil
    var precision: Int? = nil
    var editable: Bool = false

    var sliderFormat: UserPropertySliderFormat {
        UserPropertySliderFormat(minimum: minimum, maximum: maximum, fraction: fraction, step: step, precision: precision)
    }
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
    @Published var authoredPropertyIDs: Set<String> = []
    private let storageKey: String
    private let explicitKey: String
    private var pendingSave: DispatchWorkItem?

    init(wallpaper: WEWallpaper) {
        storageKey = "SceneUserProperties.\(wallpaper.wallpaperDirectory.path)"
        explicitKey = "SceneUserPropertiesExplicit.\(wallpaper.wallpaperDirectory.path)"
        load(wallpaper)
    }

    func set(_ value: String, for property: SceneUserProperty) {
        set(value, forID: property.id)
    }

    func set(_ value: String, forID id: String) {
        guard values[id] != value else { return }
        values[id] = value
        AudioReactiveScriptEngine.shared.setUserProperties(values)
        pendingSave?.cancel()
        let snapshot = values
        let work = DispatchWorkItem { [storageKey, explicitKey] in
            UserDefaults.standard.set(snapshot, forKey: storageKey)
            UserDefaults.standard.set(true, forKey: explicitKey)
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func trailingOrder(offset: Int, index: Int) -> Int {
        Int.max - max(0, offset - index)
    }

    private func load(_ wallpaper: WEWallpaper) {
          guard let data = try? Data(contentsOf: wallpaper.wallpaperDirectory.appending(path: "project.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
          let rawProperties = ((root["general"] as? [String: Any])?["properties"] as? [String: [String: Any]]) ?? [:]
                authoredPropertyIDs = Set(rawProperties.keys)
        properties = rawProperties.compactMap { (key: String, raw: [String: Any]) -> SceneUserProperty? in
            // Untyped entries are notice/header rows in WE ("text" type).
            let type = (raw["type"] as? String)?.lowercased() ?? "text"
            let rawText = raw["text"] as? String ?? ""
            let plainTitle = UserPropertyHTML.containsMarkup(rawText) ? UserPropertyHTML.plainText(rawText) : rawText
            let options = (raw["options"] as? [[String: Any]] ?? []).compactMap { option -> (String, String)? in
                guard let label = option["label"] as? String, let optionValue = option["value"] else { return nil }
                return (sceneUserPropertyTitle(label), sceneUserPropertyString(optionValue))
            }
            let defaultValue = raw["value"].map(sceneUserPropertyString)
                ?? (type == "combo" ? options.first?.1 : nil)
                ?? (type == "bool" ? "false" : "")
            var property = SceneUserProperty(id: key, title: sceneUserPropertyTitle(plainTitle), type: type,
                                             order: (raw["order"] as? NSNumber)?.intValue ?? Int.max,
                                             defaultValue: defaultValue, options: options,
                                             minimum: (raw["min"] as? NSNumber)?.doubleValue ?? 0,
                                             maximum: (raw["max"] as? NSNumber)?.doubleValue ?? 1)
            property.condition = (raw["condition"] as? String).flatMap(UserPropertyCondition.init)
            property.rawText = rawText
            property.fraction = (raw["fraction"] as? NSNumber)?.boolValue ?? true
            property.step = (raw["step"] as? NSNumber)?.doubleValue
            property.precision = (raw["precision"] as? NSNumber)?.intValue
            property.editable = (raw["editable"] as? NSNumber)?.boolValue ?? false
            return property
        }
        .sorted { ($0.order, $0.id) < ($1.order, $1.id) }
        let wallpaperType = wallpaper.project.type.lowercased()
        let isScene = wallpaperType == "scene"
        // Video goes through the same Metal scene renderer when that framework is selected, so it
        // gets the same adjustments and effect stack. Controls that need scene.json — layer
        // visibility and text layers — stay scene-only.
        let usesSceneRenderer: Bool
        if isScene {
            usesSceneRenderer = true
        } else if wallpaperType == "video" || wallpaperType == "remote-video" {
            // Read the persisted blob rather than the main-actor view model: this loader is nonisolated.
            let stored = UserDefaults.standard.data(forKey: "GlobalSettings")
                .flatMap { try? JSONDecoder().decode(GlobalSettings.self, from: $0) }
            usesSceneRenderer = (stored ?? GlobalSettings()).videoFramework == .metal
        } else {
            usesSceneRenderer = false
        }
        if usesSceneRenderer {
            let visibilityProperties = isScene
                ? undeclaredVisibilityToggles(for: wallpaper, excluding: Set(properties.map(\.id)))
                : []
            authoredPropertyIDs.formUnion(visibilityProperties.filter { $0.id == "hyperdrive" }.map(\.id))
            properties.append(contentsOf: [
                SceneUserProperty(id: "_owe_hue", title: "Hue", type: "slider", order: Int.max - 5, defaultValue: "0", options: [], minimum: -Double.pi, maximum: Double.pi),
                SceneUserProperty(id: "_owe_saturation", title: "Saturation", type: "slider", order: Int.max - 4, defaultValue: "1", options: [], minimum: 0, maximum: 2),
                SceneUserProperty(id: "_owe_bloom", title: "Bloom", type: "slider", order: Int.max - 3, defaultValue: "1", options: [], minimum: 0, maximum: 2),
                SceneUserProperty(id: "_owe_blur", title: "Blur", type: "slider", order: Int.max - 2, defaultValue: "1", options: [], minimum: 0, maximum: 2),
                SceneUserProperty(id: "_owe_speed", title: "Animation Speed", type: "slider", order: Int.max - 1, defaultValue: "1", options: [], minimum: 0, maximum: 2)
            ])
            // Mouse parallax (setting keys kept from when it lived with the native effects).
            properties.append(contentsOf: [
                SceneUserProperty(id: "_owe_effect_enabled_parallax", title: "Mouse Parallax", type: "bool",
                                  order: Int.max - 7, defaultValue: "false", options: [], minimum: 0, maximum: 1),
                SceneUserProperty(id: "_owe_effect_parallax_amount", title: "Parallax Amount", type: "slider",
                                  order: Int.max - 6, defaultValue: "1", options: [], minimum: 0, maximum: 2)
            ])
            // Some scenes gate a layer's visibility on a user property (e.g. a "dark"/"colored" variant
            // toggle) that the author forgot to declare in project.json; expose the simple on/off ones
            // anyway since the renderer already honors any visibleUserProperty by name.
            authoredPropertyIDs.formUnion(visibilityProperties.map(\.id))
            properties.append(contentsOf: visibilityProperties)
            let textLayers = isScene ? textObjectsInScene(for: wallpaper) : []
            textObjects = textLayers
            for (index, textLayer) in textLayers.enumerated() {
                let prefix = "_owe_text_\(textLayer.id)_"
                properties.append(contentsOf: [
                    // Title is empty: the checkbox sits next to the text layer's own name, so "Enabled" would be redundant.
                    SceneUserProperty(id: prefix + "enabled", title: "", type: "bool", order: trailingOrder(offset: 110, index: index), defaultValue: "true", options: [], minimum: 0, maximum: 1),
                    SceneUserProperty(id: prefix + "font", title: "Font", type: "textinput", order: trailingOrder(offset: 100, index: index), defaultValue: textLayer.font, options: [], minimum: 0, maximum: 1),
                    SceneUserProperty(id: prefix + "size", title: "Font Size", type: "slider", order: trailingOrder(offset: 90, index: index), defaultValue: String(textLayer.size), options: [], minimum: 1, maximum: 256),
                    SceneUserProperty(id: prefix + "bold", title: "Bold", type: "bool", order: trailingOrder(offset: 80, index: index), defaultValue: "false", options: [], minimum: 0, maximum: 1),
                    SceneUserProperty(id: prefix + "italic", title: "Italic", type: "bool", order: trailingOrder(offset: 70, index: index), defaultValue: "false", options: [], minimum: 0, maximum: 1),
                    SceneUserProperty(id: prefix + "color", title: "Color", type: "color", order: trailingOrder(offset: 60, index: index), defaultValue: "1 1 1", options: [], minimum: 0, maximum: 1),
                    SceneUserProperty(id: prefix + "opacity", title: "Transparency", type: "slider", order: trailingOrder(offset: 50, index: index), defaultValue: "1", options: [], minimum: 0, maximum: 1)
                ])
            }
        }
        values = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String] ?? [:]
        for property in properties where values[property.id] == nil {
            values[property.id] = property.defaultValue
        }
        let additionalControlsVersionKey = "SceneAdditionalControlsVersion.\(wallpaper.wallpaperDirectory.path)"
        if UserDefaults.standard.integer(forKey: additionalControlsVersionKey) < 1 {
            for key in values.keys where key.hasPrefix("_owe_effect_enabled_")
                || (key.hasPrefix("_owe_text_") && key.hasSuffix("_enabled") && values[key] == "false") {
                values[key] = "false"
            }
            UserDefaults.standard.set(values, forKey: storageKey)
            UserDefaults.standard.set(1, forKey: additionalControlsVersionKey)
        }
        if UserDefaults.standard.integer(forKey: additionalControlsVersionKey) < 2 {
            for key in values.keys where key.hasPrefix("_owe_text_") && key.hasSuffix("_enabled") {
                values[key] = "true"
            }
            UserDefaults.standard.set(values, forKey: storageKey)
            UserDefaults.standard.set(2, forKey: additionalControlsVersionKey)
        }
        AudioReactiveScriptEngine.shared.setUserProperties(values)
    }

    /// Simple on/off `visibleUserProperty` gates (no string variant condition) that the author never
    /// declared in project.json. Condition-based "pick one of N" gates are skipped since we have no
    /// authored labels for their valid values.
    private func undeclaredVisibilityToggles(for wallpaper: WEWallpaper,
                                             excluding declaredIds: Set<String>) -> [SceneUserProperty] {
        let sceneFile = wallpaper.project.file
        let packageURL = wallpaper.wallpaperDirectory.appending(path: (sceneFile as NSString).deletingPathExtension + ".pkg")
        guard let package = try? PKGParser(url: packageURL),
              let scene = try? package.extractJSON(named: sceneFile, as: WEScene.self) else { return [] }

        var defaults: [String: String] = [:]
        func record(property: String?, value: Bool?, condition: String?) {
            guard let property, condition == nil, !declaredIds.contains(property), defaults[property] == nil else { return }
            defaults[property] = (value ?? true) ? "true" : "false"
        }
        for object in scene.objects {
            record(property: object.visibleUserProperty, value: object.visible, condition: object.visibleCondition)
            for effect in object.effects ?? [] {
                record(property: effect.visibleUserProperty, value: effect.visible, condition: effect.visibleCondition)
            }
        }
        return defaults.enumerated().map { index, entry in
            SceneUserProperty(id: entry.key, title: entry.key.capitalized, type: "bool",
                              order: trailingOrder(offset: 45, index: index), defaultValue: entry.value, options: [], minimum: 0, maximum: 1)
        }
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
    @ObservedObject private var musicSync = VideoMusicSyncStore.shared
    private let wallpaper: WEWallpaper

    init(wallpaper: WEWallpaper) {
        self.wallpaper = wallpaper
        _model = StateObject(wrappedValue: SceneUserPropertiesModel(wallpaper: wallpaper))
    }

    private var isVideo: Bool { SceneWallpaperViewModel.isVideoType(wallpaper.project.type) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            let wallpaperProperties = model.properties.filter {
                model.authoredPropertyIDs.contains($0.id) && ($0.condition?.evaluate(model.values) ?? true)
            }
            if !wallpaperProperties.isEmpty {
                CollapsibleSection(title: "Wallpaper Settings") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(wallpaperProperties) { property in
                            propertyView(property)
                        }
                    }
                }
            }
            let adjustmentProperties = model.properties.filter { property in
                property.id.hasPrefix("_owe_") && !isTextProperty(property)
            }
            if !adjustmentProperties.isEmpty || isVideo {
                CollapsibleSection(title: "User Scene Settings") {
                    VStack(alignment: .leading, spacing: 12) {
                        if isVideo {
                            videoMusicSyncControls
                        }
                        if !adjustmentProperties.isEmpty {
                            DisclosureGroup("User Adjustments") {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(adjustmentProperties) { property in
                                        propertyView(property)
                                    }
                                }
                                .padding(.top, 4)
                            }
                        }
                        if !model.textObjects.isEmpty {
                            DisclosureGroup("Our Text") {
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
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }


    @ViewBuilder
    private var videoMusicSyncControls: some View {
        DisclosureGroup("Sync Video to Music") {
            VStack(alignment: .leading, spacing: 10) {
                videoMusicSyncRow(title: "Zoom", enabledKey: "zoomEnabled", amountKey: "zoomAmount",
                                  range: 0...0.5, defaultAmount: 0.08, suffix: "x")
                videoMusicSyncRow(title: "Pace", enabledKey: "paceEnabled", amountKey: "paceAmount",
                                  range: -1...1, defaultAmount: 0.25, suffix: "x")
                videoMusicSyncRow(title: "Tilt", enabledKey: "tiltEnabled", amountKey: "tiltAmount",
                                  range: -15...15, defaultAmount: 3, suffix: "deg")
                videoMusicSyncRow(title: "Saturation", enabledKey: "saturationEnabled", amountKey: "saturationAmount",
                                  range: -1...2, defaultAmount: 0.6, suffix: "x")
            }
            .padding(.top, 6)
        }
    }

    private func videoMusicSyncRow(title: String, enabledKey: String, amountKey: String,
                                   range: ClosedRange<Double>, defaultAmount: Double, suffix: String) -> some View {
        let wallpaper = self.wallpaper
        let isEnabled = Binding<Bool>(
            get: { VideoMusicSyncSettings.bool(wallpaper, enabledKey) },
            set: { VideoMusicSyncStore.shared.set($0, wallpaper, enabledKey) }
        )
        let amount = Binding<Double>(
            get: { VideoMusicSyncSettings.double(wallpaper, amountKey, default: defaultAmount) },
            set: { VideoMusicSyncStore.shared.set($0, wallpaper, amountKey) }
        )
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Toggle("Sync \(title)", isOn: isEnabled)
                    .toggleStyle(.checkbox)
                infoButton(SceneHelp.musicSync(title))
            }
            if isEnabled.wrappedValue {
                HStack {
                    Text("Amount")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    NumericSliderInput(value: amount, range: range,
                                       defaultValue: defaultAmount,
                                       suffix: suffix,
                                       fractionDigits: 3,
                                       sliderWidth: 100,
                                       fieldWidth: 64)
                }
            }
        }
    }

    private func isTextProperty(_ property: SceneUserProperty) -> Bool {
        property.id.hasPrefix("_owe_text_")
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
                let usesDegrees = property.id.hasSuffix("_direction")
                let format = property.sliderFormat
                let rawValue = Binding<Double>(
                    get: { Double(model.values[property.id] ?? property.defaultValue) ?? property.minimum },
                    set: { model.set(format.storedString($0), for: property) }
                )
                let value = Binding<Double>(
                    get: { usesDegrees ? rawValue.wrappedValue * 180 / .pi : rawValue.wrappedValue },
                    set: { rawValue.wrappedValue = usesDegrees ? $0 * .pi / 180 : $0 }
                )
                let minimum = usesDegrees ? property.minimum * 180 / .pi : property.minimum
                let maximum = usesDegrees ? property.maximum * 180 / .pi : property.maximum
                VStack(alignment: .leading, spacing: 4) {
                    parameterLabel(property.title + (usesDegrees ? " (degrees)" : ""), help: parameterHelp(property))
                    NumericSliderInput(value: value, range: minimum...max(maximum, minimum + 0.001),
                                       defaultValue: usesDegrees
                                           ? (Double(property.defaultValue) ?? property.minimum) * 180 / .pi
                                           : Double(property.defaultValue) ?? property.minimum,
                                       fractionDigits: usesDegrees ? 3 : format.fractionDigits, fieldWidth: 76)
                    musicSyncControls(for: property, usesDegrees: usesDegrees)
                }
            case "bool":
                HStack {
                    Toggle(property.title, isOn: Binding(get: { (model.values[property.id] ?? property.defaultValue).lowercased() == "true" },
                                                          set: { model.set($0 ? "true" : "false", for: property) }))
                    infoButton(parameterHelp(property))
                }
                    .toggleStyle(.checkbox)
            case "combo":
                let selection = Binding(get: { model.values[property.id] ?? property.defaultValue },
                                        set: { model.set($0, for: property) })
                if property.editable {
                    // Editable combos accept a free value; the menu offers the authored options.
                    VStack(alignment: .leading, spacing: 4) {
                        parameterLabel(property.title, help: parameterHelp(property))
                        HStack(spacing: 4) {
                            TextField("", text: selection)
                            Menu {
                                ForEach(property.options, id: \.value) { option in
                                    Button(option.title) { selection.wrappedValue = option.value }
                                }
                            } label: { EmptyView() }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                    }
                } else {
                    Picker(selection: selection) {
                        ForEach(property.options, id: \.value) { option in Text(option.title).tag(option.value) }
                    } label: {
                        parameterLabel(property.title, help: parameterHelp(property))
                    }
                }
            case "textinput":
                HStack {
                    TextField(property.title, text: Binding(get: { model.values[property.id] ?? property.defaultValue },
                                                            set: { model.set($0, for: property) }))
                    infoButton(parameterHelp(property))
                }
            case "color":
                ColorPicker(selection: Binding(
                    get: { colorValue(model.values[property.id] ?? property.defaultValue) },
                    set: { model.set(colorString($0), for: property) }
                ), supportsOpacity: false) {
                    parameterLabel(property.title, help: parameterHelp(property))
                }
                .anchorsColorPanel()
            case "file", "directory", "texture":
                pathPicker(property)
            case "usershortcut":
                VStack(alignment: .leading, spacing: 2) {
                    Button(property.title.isEmpty ? "Shortcut" : property.title) {}
                        .disabled(true)
                    Text("Custom shortcuts are not supported yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            default:
                // "text" and untyped rows: author notices, headers and dividers.
                noticeRow(property)
            }
    }

    @ViewBuilder
    private func noticeRow(_ property: SceneUserProperty) -> some View {
        let text = property.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            Spacer().frame(height: 4)
        } else {
            Text(UserPropertyHTML.attributed(sceneUserPropertyTitle(text)))
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pathPicker(_ property: SceneUserProperty) -> some View {
        let current = model.values[property.id] ?? property.defaultValue
        return VStack(alignment: .leading, spacing: 4) {
            parameterLabel(property.title, help: parameterHelp(property))
            HStack(spacing: 6) {
                Text(current.isEmpty ? "None" : (current as NSString).lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(current.isEmpty ? .secondary : .primary)
                    .help(current)
                Spacer()
                Button("Choose…") {
                    if let path = UserPropertyPathPanel.choose(type: property.type) {
                        model.set(path, for: property)
                    }
                }
                if !current.isEmpty {
                    Button("Clear") { model.set("", for: property) }
                }
            }
        }
    }

    @ViewBuilder
    private func musicSyncControls(for property: SceneUserProperty, usesDegrees: Bool) -> some View {
        let syncID = "\(property.id)_musicSync"
        let amountID = "\(property.id)_musicAmount"
        let isEnabled = Binding<Bool>(
            get: { (model.values[syncID] ?? "false").lowercased() == "true" },
            set: { model.set($0 ? "true" : "false", forID: syncID) }
        )
        Toggle("Sync to Music", isOn: isEnabled)
            .toggleStyle(.checkbox)
            .font(.caption)
        if isEnabled.wrappedValue {
            let rawSpan = max(property.maximum - property.minimum, 0.001)
            let displaySpan = usesDegrees ? rawSpan * 180 / .pi : rawSpan
            let amount = Binding<Double>(
                get: {
                    let raw = Double(model.values[amountID] ?? "0") ?? 0
                    return usesDegrees ? raw * 180 / .pi : raw
                },
                set: { value in
                    model.set(String(usesDegrees ? value * .pi / 180 : value), forID: amountID)
                }
            )
            HStack {
                Text("Music Amount")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                NumericSliderInput(value: amount, range: -displaySpan...displaySpan,
                                   defaultValue: 0, fractionDigits: 3,
                                   sliderWidth: 100, fieldWidth: 64)
            }
        }
    }

    private func parameterLabel(_ title: String, help: String) -> some View {
        HStack(spacing: 5) {
            Text(title)
            infoButton(help)
        }
    }

    private func infoButton(_ help: String) -> some View {
        InfoTip(help)
    }

    private func parameterHelp(_ property: SceneUserProperty) -> String {
        if property.type == "color" { return SceneHelp.parameter(key: "color") }
        // Effect controls are stored as "_owe_effect_<effect>_<parameter>"; effect names never
        // contain an underscore, so the first one separates the two.
        let prefix = "_owe_effect_"
        if property.id.hasPrefix(prefix) {
            let rest = property.id.dropFirst(prefix.count)
            if rest.hasPrefix("enabled_") {
                return SceneHelp.effect(String(rest.dropFirst("enabled_".count)))
            }
            let parts = rest.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 {
                return SceneHelp.parameter(effect: String(parts[0]), key: String(parts[1]),
                                           title: property.title)
            }
        }
        return SceneHelp.parameter(key: property.id, title: property.title)
    }

    private func colorValue(_ value: String) -> Color {
        let components = value.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
        let scale = components.max() ?? 1 > 1 ? 255.0 : 1.0
        return Color(red: (components.indices.contains(0) ? components[0] : 1) / scale,
                 green: (components.indices.contains(1) ? components[1] : 1) / scale,
                 blue: (components.indices.contains(2) ? components[2] : 1) / scale)
    }

    private func colorString(_ color: Color) -> String {
        let nsColor = NSColor(color).usingColorSpace(.deviceRGB) ?? .white
        return "\(nsColor.redComponent) \(nsColor.greenComponent) \(nsColor.blueComponent)"
    }
}
/// Open panel for `file`, `directory` and `texture` properties; returns the chosen path.
enum UserPropertyPathPanel {
    @MainActor
    static func choose(type: String) -> String? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = type == "directory"
        panel.canChooseFiles = type != "directory"
        if type == "texture" {
            panel.allowedContentTypes = [.image]
        }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
