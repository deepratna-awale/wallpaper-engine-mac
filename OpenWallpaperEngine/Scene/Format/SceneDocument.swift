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
        if key.hasPrefix("_owe_effect_enabled_") { return .rebuildContent }
        if key.hasPrefix("_owe_effect_") { return .none }

        if key.hasPrefix("_owe_text_") {
            // Font, size, style, colour and opacity are all resampled per frame.
            return key.hasSuffix("_enabled") ? .rebuildContent : .none
        }

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
    var script: String?
    var version: Int?
}

struct WECamera: Codable {
    var center: String?
    var eye: String?
    var up: String?
}

struct WESceneGeneral: Codable {
    var clearcolor: String?
    var orthogonalprojection: WEOrthogonalProjection?
    var ambientcolor: String?
    var skylightcolor: String?
    var bloom: Bool?
    var bloomstrength: Double?
    var bloomthreshold: Double?
    var bloomtint: String?
    var fov: Double?
    var nearz: Double?
    var farz: Double?
    var zoom: Double?

    // These fields can be Bool, Int, or an object {"user":..,"value":..} in different wallpapers.
    // We only need the String fields above for rendering, so skip strict decoding of the rest.

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Use try? because these fields can be plain strings OR {"user":..,"value":..} objects
        clearcolor = try? container.decodeIfPresent(String.self, forKey: .clearcolor)
        orthogonalprojection = try? container.decodeIfPresent(WEOrthogonalProjection.self, forKey: .orthogonalprojection)
        ambientcolor = try? container.decodeIfPresent(String.self, forKey: .ambientcolor)
        skylightcolor = try? container.decodeIfPresent(String.self, forKey: .skylightcolor)
        bloom = try? container.decodeIfPresent(Bool.self, forKey: .bloom)
        bloomstrength = try? container.decodeIfPresent(Double.self, forKey: .bloomstrength)
        bloomthreshold = try? container.decodeIfPresent(Double.self, forKey: .bloomthreshold)
        bloomtint = try? container.decodeIfPresent(String.self, forKey: .bloomtint)
        fov = try? container.decodeIfPresent(Double.self, forKey: .fov)
        nearz = try? container.decodeIfPresent(Double.self, forKey: .nearz)
        farz = try? container.decodeIfPresent(Double.self, forKey: .farz)
        zoom = try? container.decodeIfPresent(Double.self, forKey: .zoom)
    }

    enum CodingKeys: String, CodingKey {
        case clearcolor, orthogonalprojection, ambientcolor, skylightcolor
        case bloom, bloomstrength, bloomthreshold, bloomtint
        case fov, nearz, farz, zoom
    }
}

struct WEOrthogonalProjection: Codable {
    var width: Int
    var height: Int
}

// MARK: - Scene Objects
