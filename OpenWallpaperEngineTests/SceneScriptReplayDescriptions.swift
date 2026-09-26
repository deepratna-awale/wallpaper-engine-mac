import Foundation
@testable import OpenWallpaperEngine

/// Builds the object model's view of a replay wallpaper from its JSON: every object with its
/// transform, colour, text strings, particle instance overrides, effects and their materials'
/// constants, the way the renderer describes a loaded scene (WP11 will do it from the real
/// loaders). Values are in the object table's units: angles in radians.
enum SceneScriptReplayDescriptions {
    static func scene(_ wallpaper: SceneScriptReplayWallpaper) -> SceneScriptSceneDescription {
        let properties = wallpaper.userProperties
        var description = SceneScriptSceneDescription(
            objects: wallpaper.objects.map {
                object(json: $0.json, id: $0.id, kind: $0.kind, properties: properties, file: wallpaper.file)
            })
        if let general = wallpaper.document["general"] as? [String: Any] {
            for field in SceneScriptSceneField.allCases where !field.isCamera {
                let value = SceneScriptReplayWallpaper.resolve(general[field.rawValue], properties: properties)
                if let numbers = SceneScriptReplayWallpaper.numbers(value), numbers.count >= field.components {
                    description.settings[field] = Array(numbers.prefix(field.components))
                }
                if let animation = animation(general[field.rawValue], property: "general.\(field.rawValue)") {
                    description.animations.append(animation)
                }
            }
        }
        return description
    }

    /// A layer `thisScene.createLayer` asked for: an asset file of the wallpaper (a model or object
    /// JSON) or a configuration in scene.json form.
    static func layer(_ source: SceneScriptLayerSource, wallpaper: SceneScriptReplayWallpaper, id: Int,
                      copying: [String: Any]?) -> SceneScriptObjectDescription? {
        let json: [String: Any]
        switch source {
        case .asset(let written, let workshopID):
            // Under the script's Workshop item first, then as written (RF1).
            let found = SceneScriptLayerSource.assetPaths(written, workshopID: workshopID).lazy
                .compactMap { path in wallpaper.file(path).map { (path, $0) } }.first
            guard let (path, data) = found,
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                // Optional: a missing or unreadable asset makes `createLayer` return null, as in WE.
                return nil
            }
            json = ["image": path, "name": path].merging(object) { _, new in new }
        case .configuration(let text):
            guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
                // Optional: WE's stringifyConfig always produces JSON; anything else makes no layer.
                return nil
            }
            json = object
        case .copy:
            guard let copying else { return nil }
            json = copying
        }
        return object(json: json, id: id, kind: SceneScriptReplayWallpaper.kind(of: json),
                      properties: wallpaper.userProperties, file: wallpaper.file)
    }

    static func object(json: [String: Any], id: Int, kind: SceneScriptObjectDescription.Kind,
                       properties: [String: Any], file: (String) -> Data?) -> SceneScriptObjectDescription {
        func value(_ key: String) -> Any { SceneScriptReplayWallpaper.resolve(json[key], properties: properties) }

        var description = SceneScriptObjectDescription(kind: kind, id: id, name: json["name"] as? String ?? "",
                                                       parentID: (json["parent"] as? NSNumber)?.intValue)
        for field in SceneScriptObjectField.allCases where field.group == .layer && !field.isReadOnly {
            guard let numbers = SceneScriptReplayWallpaper.numbers(value(field.rawValue)),
                  numbers.count >= field.components else { continue }
            let components = Array(numbers.prefix(field.components))
            description.values[field] = field.type == .degrees ? components.map { $0 * .pi / 180 } : components
        }
        if let size = SceneScriptReplayWallpaper.numbers(value("size")), size.count >= 2 {
            description.values[.size] = Array(size.prefix(2))
        }
        if let overrides = json["instanceoverride"] as? [String: Any] {
            let instanceFields: [String: SceneScriptObjectField] = [
                "alpha": .instanceAlpha, "size": .instanceSize, "count": .instanceCount, "speed": .instanceSpeed,
                "lifetime": .instanceLifetime, "rate": .instanceRate,
            ]
            for (key, field) in instanceFields {
                let resolved = SceneScriptReplayWallpaper.resolve(overrides[key], properties: properties)
                if let numbers = SceneScriptReplayWallpaper.numbers(resolved), numbers.count == 1 {
                    description.values[field] = numbers
                }
            }
        }
        for field in SceneScriptStringField.allCases {
            if let text = value(field.rawValue) as? String { description.strings[field] = text }
        }
        description.effects = ((json["effects"] as? [Any]) ?? []).compactMap { entry in
            guard let effect = entry as? [String: Any] else { return nil }
            return self.effect(effect, properties: properties)
        }
        for key in json.keys.sorted() where key != "effects" && key != "instanceoverride" {
            if let animation = animation(json[key], property: key) { description.animations.append(animation) }
        }
        let overrides = (json["instanceoverride"] as? [String: Any]) ?? [:]
        for key in overrides.keys.sorted() {
            if let animation = animation(overrides[key], property: "instanceoverride.\(key)") {
                description.animations.append(animation)
            }
        }
        if kind == .image, let image = json["image"] as? String {
            description.textureAnimation = textureAnimation(model: image, file: file)
        }
        if let data = try? JSONSerialization.data(withJSONObject: json) {
            description.initialConfigurationJSON = String(decoding: data, as: UTF8.self)
        }
        return description
    }

    private static func effect(_ json: [String: Any], properties: [String: Any]) -> SceneScriptObjectDescription.Effect {
        let file = json["file"] as? String ?? ""
        let fileName = URL(fileURLWithPath: file).deletingLastPathComponent().lastPathComponent
        let name = (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fileName
        let visibleValue = SceneScriptReplayWallpaper.resolve(json["visible"] ?? true, properties: properties)
        let visible = (visibleValue as? NSNumber)?.boolValue ?? true
        let materials = ((json["passes"] as? [Any]) ?? []).map { entry -> SceneScriptObjectDescription.Material in
            let constants = ((entry as? [String: Any])?["constantshadervalues"] as? [String: Any]) ?? [:]
            var material = SceneScriptObjectDescription.Material(constants: constants.keys.sorted().compactMap { key in
                let resolved = SceneScriptReplayWallpaper.resolve(constants[key], properties: properties)
                guard let numbers = SceneScriptReplayWallpaper.numbers(resolved) else { return nil }
                return SceneScriptObjectDescription.Constant(name: key, value: Array(numbers.prefix(4)))
            })
            material.animations = constants.keys.sorted().compactMap { animation(constants[$0], property: $0) }
            return material
        }
        var effect = SceneScriptObjectDescription.Effect(name: name, visible: visible, materials: materials)
        effect.animations = animation(json["visible"], property: "visible").map { [$0] } ?? []
        return effect
    }

    // MARK: - Animations

    /// A property's timeline animation (`{"value", "animation": {"c0": keys, "options": {…}}}`).
    static func animation(_ field: Any?, property: String) -> SceneScriptAnimationDescription? {
        guard let animation = (field as? [String: Any])?["animation"] as? [String: Any] else { return nil }
        let options = animation["options"] as? [String: Any] ?? [:]
        let fps = (options["fps"] as? NSNumber)?.doubleValue ?? 30
        let length = (options["length"] as? NSNumber)?.intValue ?? 0
        let startPaused = (options["startpaused"] as? NSNumber)?.boolValue ?? false
        return SceneScriptAnimationDescription(name: options["name"] as? String ?? "", fps: fps, frameCount: length,
                                               duration: fps > 0 ? Double(length) / fps : 0, playing: !startPaused,
                                               property: property)
    }

    /// The spritesheet animation of an image's texture: model JSON → material → first texture's
    /// `.tex`, whose `TEXS` block lists the frames and their durations. Nil for a still texture.
    static func textureAnimation(model path: String, file: (String) -> Data?) -> SceneScriptAnimationDescription? {
        guard let modelData = file(path),
              let model = (try? JSONSerialization.jsonObject(with: modelData)) as? [String: Any],
              let materialPath = model["material"] as? String,
              let materialData = file(materialPath),
              let material = (try? JSONSerialization.jsonObject(with: materialData)) as? [String: Any],
              let pass = (material["passes"] as? [[String: Any]])?.first,
              let texture = (pass["textures"] as? [Any])?.first as? String,
              let tex = file("materials/\(texture).tex") else {
            // Optional: models without a material or a texture file have no texture animation.
            return nil
        }
        guard let frames = spriteFrames(Array(tex)), !frames.isEmpty else { return nil }
        let duration = frames.reduce(0, +)
        return SceneScriptAnimationDescription(name: "", fps: duration > 0 ? Double(frames.count) / duration : 0,
                                               frameCount: frames.count, duration: duration, playing: true)
    }

    /// The frame durations of the last `TEXS000n` block of a `.tex`, or nil when it has none.
    static func spriteFrames(_ bytes: [UInt8]) -> [Double]? {
        let marker = Array("TEXS000".utf8)
        guard bytes.count > marker.count + 2 else { return nil }
        var found: Int?
        var index = bytes.count - marker.count - 2
        while index >= 0 {
            if bytes[index] == marker[0], Array(bytes[index..<(index + marker.count)]) == marker,
               bytes[index + marker.count + 1] == 0 {
                found = index
                break
            }
            index -= 1
        }
        guard let start = found else { return nil }
        let version = bytes[start + marker.count]
        var cursor = start + marker.count + 2
        func u32() -> UInt32? {
            guard cursor + 4 <= bytes.count else { return nil }
            defer { cursor += 4 }
            var value: UInt32 = 0
            for offset in 0..<4 { value |= UInt32(bytes[cursor + offset]) << UInt32(8 * offset) }
            return value
        }
        guard let count = u32(), count > 0, count < 100_000 else { return nil }
        if version == UInt8(ascii: "3") { _ = u32(); _ = u32() }
        var durations: [Double] = []
        for _ in 0..<count {
            guard u32() != nil, let bits = u32() else { return nil }
            durations.append(Double(Float(bitPattern: bits)))
            for _ in 0..<6 { guard u32() != nil else { return nil } }
        }
        return durations
    }
}
