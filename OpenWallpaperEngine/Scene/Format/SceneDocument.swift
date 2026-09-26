//
//  SceneModels.swift
//  Open Wallpaper Engine
//
//  Data models for Wallpaper Engine scene.json structure.
//  Decoded from scene.pkg → scene.json and referenced JSON files.
//

import Foundation

func sceneUserPropertyString(_ value: Any) -> String {
    if let number = value as? NSNumber {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "true" : "false"
        }
        return number.stringValue
    }
    return String(describing: value)
}

func sceneAuthoredEffectOverrideKey(objectID: Int, effectIndex: Int, parameter: String) -> String {
    "_owe_authored_effect_\(objectID)_\(effectIndex)_\(parameter.lowercased())"
}

func sceneAuthoredEffectEnabledKey(objectID: Int, effectIndex: Int) -> String {
    "_owe_authored_effect_\(objectID)_\(effectIndex)_enabled"
}

/// How much work a changed user-property key actually requires from the renderer.
/// Most sliders are sampled live every frame and need no rebuild at all; only overrides that are
/// baked into the decoded scene JSON justify re-parsing the package.
enum SceneChangeImpact: Int, Comparable {
    case none = 0
    case rebuildContent = 1
    case reloadScene = 2

    static func < (lhs: SceneChangeImpact, rhs: SceneChangeImpact) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    static func impact(of key: String) -> SceneChangeImpact {
        // Syncing an effect parameter turns its baked literal into a live binding.
        if key.hasPrefix("_owe_authored_effect_"), key.hasSuffix("_musicSync") { return .rebuildContent }
        // Music-sync companions only modulate values that are already sampled live.
        if key.hasSuffix("_musicSync") || key.hasSuffix("_musicAmount") { return .none }

        if key.hasPrefix("_owe_scene_object_") {
            // Visibility is resolved while building content; JSON/origin edits are baked in decodeScene.
            return key.hasSuffix("_visible") ? .rebuildContent : .reloadScene
        }
        if key.hasPrefix("_owe_scene_asset_") { return .reloadScene }

        if key.hasPrefix("_owe_authored_effect_") {
            // Per-object constants are captured when effects are built.
            return .rebuildContent
        }
        // Mouse parallax (the only remaining "_owe_effect_" keys) is read by the renderer every frame.
        if key.hasPrefix("_owe_effect_") { return .none }

        if key.hasPrefix("_owe_text_") {
            // Font, size, style, colour and opacity are all resampled per frame.
            return key.hasSuffix("_enabled") ? .rebuildContent : .none
        }

        // WE's image filter and colour options are read by the post-processing every frame.
        if WEColorCorrectionProperty.contains(key) { return .none }

        switch key {
        case "_owe_hue", "_owe_saturation", "_owe_bloom", "_owe_blur", "_owe_speed":
            return .none
        default:
            // Authored properties can gate layer/effect visibility, so rebuild to be safe.
            return .rebuildContent
        }
    }

    static func aggregate(_ keys: [String]) -> SceneChangeImpact {
        keys.reduce(.none) { Swift.max($0, impact(of: $1)) }
    }
}

func sceneObjectVisibilityKey(objectID: Int) -> String {
    "_owe_scene_object_\(objectID)_visible"
}

// MARK: - Top-level Scene

struct WEScene: Decodable {
    var camera: WECamera
    var general: WESceneGeneral
    var objects: [WESceneObject]
    var effects: [String]?
    var version: Int?
}

struct WECamera: Codable {
    var center: String?
    var eye: String?
    var up: String?
}

struct WESceneGeneral: Decodable {
    var orthogonalprojection: WEOrthogonalProjection?
    /// `orthogonalprojection` is present but `null`: WE renders the scene with its perspective camera.
    var usesPerspectiveProjection = false
    var bloomtint: String?
    var fov: Double?
    var nearz: Double?
    var farz: Double?
    var zoom: Double?
    /// The light budget; nil when the scene has none, which leaves every new-style light unused.
    var lightconfig: WELightConfig?
    /// Every bindable field in its full authored form (literal, `user`, `script`, `animation`).
    var values: [SceneGeneralValueField: SceneRawValue] = [:]

    // Literal fallbacks of the bindable fields.
    var clearcolor: String? { values[.clearcolor]?.literalString }
    var ambientcolor: String? { values[.ambientcolor]?.literalString }
    var skylightcolor: String? { values[.skylightcolor]?.literalString }
    var bloom: Bool? { values[.bloom]?.literalBool }
    var bloomstrength: Double? { values[.bloomstrength]?.literalDouble }
    var bloomthreshold: Double? { values[.bloomthreshold]?.literalDouble }
    var hdr: Bool? { values[.hdr]?.literalBool }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        let info = decoder.userInfo
        for field in SceneGeneralValueField.allCases {
            if let raw = container.decodeLogged(SceneRawValue.self, forKey: AnyCodingKey(stringValue: field.rawValue), userInfo: info) {
                values[field] = raw
            }
        }
        let projectionKey = AnyCodingKey(stringValue: "orthogonalprojection")
        if container.contains(projectionKey), (try? container.decodeNil(forKey: projectionKey)) == true {
            // `try?`: decodeNil only fails when the key is missing, which `contains` just ruled out.
            usesPerspectiveProjection = true
        } else {
            orthogonalprojection = container.decodeLogged(WEOrthogonalProjection.self, forKey: projectionKey, userInfo: info)
        }
        bloomtint = container.decodeLogged(SceneRawValue.self, forKey: AnyCodingKey(stringValue: "bloomtint"), userInfo: info)?.literalString
        fov = container.decodeLogged(SceneRawValue.self, forKey: AnyCodingKey(stringValue: "fov"), userInfo: info)?.literalDouble
        nearz = container.decodeLogged(SceneRawValue.self, forKey: AnyCodingKey(stringValue: "nearz"), userInfo: info)?.literalDouble
        farz = container.decodeLogged(SceneRawValue.self, forKey: AnyCodingKey(stringValue: "farz"), userInfo: info)?.literalDouble
        zoom = container.decodeLogged(SceneRawValue.self, forKey: AnyCodingKey(stringValue: "zoom"), userInfo: info)?.literalDouble
        lightconfig = container.decodeLogged(WELightConfig.self, forKey: AnyCodingKey(stringValue: "lightconfig"), userInfo: info)
    }
}

struct WEOrthogonalProjection: Codable {
    var width: Int
    var height: Int
}

// MARK: - Scene Objects
