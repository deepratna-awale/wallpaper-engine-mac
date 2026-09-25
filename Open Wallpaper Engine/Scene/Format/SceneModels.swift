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

/// Many WE scene fields can be either a plain value or a {"script":"..","value":..} object.
/// This wrapper decodes the plain value and silently ignores script objects.
private func decodeFlexible<T: Decodable>(_ type: T.Type, container: KeyedDecodingContainer<WESceneObject.CodingKeys>, key: WESceneObject.CodingKeys) -> T? {
    try? container.decodeIfPresent(T.self, forKey: key)
}

struct WESceneObject: Decodable {
    // Common
    var id: Int?
    var parent: Int?
    var name: String?
    var origin: String?
    var originScript: String?
    var originScriptProperties: [String: String] = [:]
    var originAnimation: WEVectorKeyframeAnimation?
    var scale: String?
    var scaleScript: String?
    var scaleAnimation: WEVectorKeyframeAnimation?
    var angles: String?
    var anglesScript: String?
    var anglesAnimation: WEVectorKeyframeAnimation?
    var visible: Bool?
    var visibleCondition: String?
    var visibleUserProperty: String?
    var visibleScript: String?
    var effects: [WEObjectEffect]?
    var shape: String?

    // Text objects
    var textValue: String?
    var textScript: String?
    var textScriptProperties: [String: String] = [:]
    var font: String?
    var pointsize: Double?
    var horizontalalign: String?
    var verticalalign: String?
    /// Authored as either a scalar ("32") or a pair ("32 32").
    var padding: String?
    var maxwidth: Double?
    var maxrows: Int?
    var limitwidth: Bool?
    var limitrows: Bool?
    var limituseellipsis: Bool?

    // Image objects
    var image: String?       // path to model JSON
    var alpha: Double?
    var alphaScript: String?
    var alphaAnimation: WEKeyframeAnimation?
    var brightness: Double?
    var brightnessScript: String?
    var color: String?
    var colorScript: String?
    var colorBlendMode: Int?
    var size: String?
    var sizeScript: String?
    var sizeAnimation: WEVectorKeyframeAnimation?
    var alignment: String?
    var solid: Bool?
    var copybackground: Bool?
    var parallaxDepth: String?
    var perspective: Bool?

    // Particle objects
    var particle: String?    // path to particle JSON
    var instanceoverride: WEInstanceOverride?

    enum CodingKeys: String, CodingKey {
        case id, parent, name, origin, scale, angles, visible, effects, text, font, pointsize, horizontalalign, verticalalign
        case padding, maxwidth, maxrows, limitwidth, limitrows, limituseellipsis
        case image, alpha, brightness, color, colorBlendMode, size, alignment, shape
        case solid, copybackground, parallaxDepth, perspective
        case particle, instanceoverride
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Fields that are always simple types
        id = try? c.decodeIfPresent(Int.self, forKey: .id)
        parent = try? c.decodeIfPresent(Int.self, forKey: .parent)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        image = try? c.decodeIfPresent(String.self, forKey: .image)
        particle = try? c.decodeIfPresent(String.self, forKey: .particle)
        instanceoverride = try? c.decodeIfPresent(WEInstanceOverride.self, forKey: .instanceoverride)
        effects = try? c.decodeIfPresent([WEObjectEffect].self, forKey: .effects)
        shape = try? c.decodeIfPresent(String.self, forKey: .shape)
            if let scriptedText = try? c.decode(WEScriptedProperty.self, forKey: .text) {
            textValue = scriptedText.stringValue
            textScript = scriptedText.script
            textScriptProperties = scriptedText.scriptProperties
        } else {
            textValue = try? c.decodeIfPresent(String.self, forKey: .text)
            textScript = nil
        }
        font = try? c.decodeIfPresent(String.self, forKey: .font)
        pointsize = try? c.decodeIfPresent(Double.self, forKey: .pointsize)
        horizontalalign = try? c.decodeIfPresent(String.self, forKey: .horizontalalign)
        verticalalign = try? c.decodeIfPresent(String.self, forKey: .verticalalign)
        padding = (try? c.decodeIfPresent(String.self, forKey: .padding))
            ?? (try? c.decodeIfPresent(Double.self, forKey: .padding)).map { String($0) } ?? nil
        maxwidth = try? c.decodeIfPresent(Double.self, forKey: .maxwidth)
        maxrows = try? c.decodeIfPresent(Int.self, forKey: .maxrows)
        limitwidth = try? c.decodeIfPresent(Bool.self, forKey: .limitwidth)
        limitrows = try? c.decodeIfPresent(Bool.self, forKey: .limitrows)
        limituseellipsis = try? c.decodeIfPresent(Bool.self, forKey: .limituseellipsis)

        // Fields that may be simple values or {"script":..,"value":..} objects
        let scriptedOrigin = try? c.decode(WEScriptedProperty.self, forKey: .origin)
        origin = (try? c.decodeIfPresent(String.self, forKey: .origin)) ?? scriptedOrigin?.stringValue
        originScript = scriptedOrigin?.script
        originScriptProperties = scriptedOrigin?.scriptProperties ?? [:]
        originAnimation = scriptedOrigin?.vectorAnimation
        let scriptedScale = try? c.decode(WEScriptedProperty.self, forKey: .scale)
        scale = (try? c.decodeIfPresent(String.self, forKey: .scale)) ?? scriptedScale?.stringValue
        scaleScript = scriptedScale?.script
        scaleAnimation = scriptedScale?.vectorAnimation
        let scriptedAngles = try? c.decode(WEScriptedProperty.self, forKey: .angles)
        angles = (try? c.decodeIfPresent(String.self, forKey: .angles)) ?? scriptedAngles?.stringValue
        anglesScript = scriptedAngles?.script
        anglesAnimation = scriptedAngles?.vectorAnimation
        if let conditional = try? c.decode(WEConditionalBool.self, forKey: .visible) {
            visible = conditional.value
            visibleCondition = conditional.condition
            visibleUserProperty = conditional.property
            visibleScript = conditional.script
        } else {
            visible = try? c.decodeIfPresent(Bool.self, forKey: .visible)
            visibleCondition = nil
            visibleUserProperty = nil
            visibleScript = nil
        }
        if let scriptedAlpha = try? c.decode(WEAnimatedScalar.self, forKey: .alpha) {
            alpha = scriptedAlpha.value
            alphaScript = scriptedAlpha.script
            alphaAnimation = scriptedAlpha.animation
        } else {
            alpha = try? c.decodeIfPresent(Double.self, forKey: .alpha)
            alphaScript = nil
            alphaAnimation = nil
        }
        if let scriptedBrightness = try? c.decode(WEScriptedProperty.self, forKey: .brightness) {
            brightness = scriptedBrightness.stringValue.flatMap(Double.init)
            brightnessScript = scriptedBrightness.script
        } else {
            brightness = try? c.decodeIfPresent(Double.self, forKey: .brightness)
            brightnessScript = nil
        }
        if let scriptedColor = try? c.decode(WEScriptedProperty.self, forKey: .color) {
            color = scriptedColor.stringValue
            colorScript = scriptedColor.script
        } else {
            color = try? c.decodeIfPresent(String.self, forKey: .color)
            colorScript = nil
        }
        colorBlendMode = try? c.decodeIfPresent(Int.self, forKey: .colorBlendMode)
        let scriptedSize = try? c.decode(WEScriptedProperty.self, forKey: .size)
        size = (try? c.decodeIfPresent(String.self, forKey: .size)) ?? scriptedSize?.stringValue
        sizeScript = scriptedSize?.script
        sizeAnimation = scriptedSize?.vectorAnimation
        alignment = try? c.decodeIfPresent(String.self, forKey: .alignment)
        solid = try? c.decodeIfPresent(Bool.self, forKey: .solid)
        copybackground = try? c.decodeIfPresent(Bool.self, forKey: .copybackground)
        parallaxDepth = try? c.decodeIfPresent(String.self, forKey: .parallaxDepth)
        perspective = try? c.decodeIfPresent(Bool.self, forKey: .perspective)
    }
}

struct WEObjectEffect: Decodable {
    let file: String
    let visible: Bool?
    let visibleCondition: String?
    let visibleUserProperty: String?
    let passes: [WEObjectEffectPass]?

    enum CodingKeys: String, CodingKey { case file, visible, passes }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        file = try container.decode(String.self, forKey: .file)
        if let conditional = try? container.decode(WEConditionalBool.self, forKey: .visible) {
            visible = conditional.value
            visibleCondition = conditional.condition
            visibleUserProperty = conditional.property
        } else {
            visible = try? container.decodeIfPresent(Bool.self, forKey: .visible)
            visibleCondition = nil
            visibleUserProperty = nil
        }
        passes = try? container.decodeIfPresent([WEObjectEffectPass].self, forKey: .passes)
    }
}

struct WEObjectEffectPass: Decodable {
    let constantshadervalues: [String: WEEffectConstant]?
    let textures: [String?]?
    let combos: [String: Int]?
}

struct WEEffectConstant: Decodable {
    let number: Double?
    let string: String?
    let script: String?

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            number = try? container.decodeIfPresent(Double.self, forKey: .value)
            string = try? container.decodeIfPresent(String.self, forKey: .value)
            script = try? container.decodeIfPresent(String.self, forKey: .script)
        } else {
            let container = try decoder.singleValueContainer()
            number = try? container.decode(Double.self)
            string = try? container.decode(String.self)
            script = nil
        }
    }

    enum CodingKeys: String, CodingKey { case value, script }
}

private struct WEConditionalBool: Decodable {
    let value: Bool?
    let condition: String?
    let property: String?
    let script: String?

    enum CodingKeys: String, CodingKey { case value, user, script }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = (try? container.decodeIfPresent(Bool.self, forKey: .value))
            ?? (try? container.decodeIfPresent(Int.self, forKey: .value)).map { $0 != 0 }
        script = try container.decodeIfPresent(String.self, forKey: .script)
        if let property = try? container.decode(String.self, forKey: .user) {
            self.property = property
            condition = nil
        } else {
            let user = try? container.decode([String: String].self, forKey: .user)
            property = user?["name"]
            condition = user?["condition"]
        }
    }
}

struct WEKeyframeAnimation: Decodable {
    let keyframes: [WEKeyframe]
    let mode: String?
    let duration: Double?
    let startPaused: Bool?
    let wrapLoop: Bool?

    enum CodingKeys: String, CodingKey { case keyframes, frames, mode, seconds, duration, startPaused, startpaused, wrapLoop, wraploop }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyframes = ((try? container.decode([WEKeyframe].self, forKey: .keyframes))
            ?? (try? container.decode([WEKeyframe].self, forKey: .frames)) ?? [])
            .sorted { $0.frame < $1.frame }
        mode = try? container.decodeIfPresent(String.self, forKey: .mode)
        duration = (try? container.decodeIfPresent(Double.self, forKey: .seconds))
            ?? (try? container.decodeIfPresent(Double.self, forKey: .duration))
        startPaused = (try? container.decodeIfPresent(Bool.self, forKey: .startPaused))
            ?? (try? container.decodeIfPresent(Bool.self, forKey: .startpaused))
        wrapLoop = (try? container.decodeIfPresent(Bool.self, forKey: .wrapLoop))
            ?? (try? container.decodeIfPresent(Bool.self, forKey: .wraploop))
    }
}

struct WEKeyframe: Decodable {
    let frame: Double
    let value: Double
    let easing: String?
    let bezier: [Double]?
    let inTangent: Double?
    let outTangent: Double?

    enum CodingKeys: String, CodingKey { case frame, value, easing, interpolation, bezier, curve, inTangent, outTangent, intangent, outtangent }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        frame = try container.decode(WEFlexibleDouble.self, forKey: .frame).wrappedValue ?? 0
        value = try container.decode(WEFlexibleDouble.self, forKey: .value).wrappedValue ?? 0
        easing = (try? container.decodeIfPresent(String.self, forKey: .easing)) ?? (try? container.decodeIfPresent(String.self, forKey: .interpolation))
        bezier = (try? container.decodeIfPresent([Double].self, forKey: .bezier)) ?? (try? container.decodeIfPresent([Double].self, forKey: .curve))
        inTangent = (try? container.decodeIfPresent(Double.self, forKey: .inTangent)) ?? (try? container.decodeIfPresent(Double.self, forKey: .intangent))
        outTangent = (try? container.decodeIfPresent(Double.self, forKey: .outTangent)) ?? (try? container.decodeIfPresent(Double.self, forKey: .outtangent))
    }
}

struct WEVectorKeyframeAnimation: Decodable {
    let keyframes: [WEVectorKeyframe]
    let mode: String?
    let duration: Double?
    let startPaused: Bool?
    let wrapLoop: Bool?

    enum CodingKeys: String, CodingKey { case keyframes, frames, mode, seconds, duration, startPaused, startpaused, wrapLoop, wraploop }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyframes = ((try? container.decode([WEVectorKeyframe].self, forKey: .keyframes))
            ?? (try? container.decode([WEVectorKeyframe].self, forKey: .frames)) ?? [])
            .sorted { $0.frame < $1.frame }
        mode = try? container.decodeIfPresent(String.self, forKey: .mode)
        duration = (try? container.decodeIfPresent(Double.self, forKey: .seconds))
            ?? (try? container.decodeIfPresent(Double.self, forKey: .duration))
        startPaused = (try? container.decodeIfPresent(Bool.self, forKey: .startPaused))
            ?? (try? container.decodeIfPresent(Bool.self, forKey: .startpaused))
        wrapLoop = (try? container.decodeIfPresent(Bool.self, forKey: .wrapLoop))
            ?? (try? container.decodeIfPresent(Bool.self, forKey: .wraploop))
    }
}

struct WEVectorKeyframe: Decodable {
    let frame: Double
    let value: WEFlexValue
    let easing: String?
    let bezier: [Double]?
    let inTangent: Double?
    let outTangent: Double?

    enum CodingKeys: String, CodingKey { case frame, value, easing, interpolation, bezier, curve, inTangent, outTangent, intangent, outtangent }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        frame = try container.decode(WEFlexibleDouble.self, forKey: .frame).wrappedValue ?? 0
        value = try container.decode(WEFlexValue.self, forKey: .value)
        easing = (try? container.decodeIfPresent(String.self, forKey: .easing)) ?? (try? container.decodeIfPresent(String.self, forKey: .interpolation))
        bezier = (try? container.decodeIfPresent([Double].self, forKey: .bezier)) ?? (try? container.decodeIfPresent([Double].self, forKey: .curve))
        inTangent = (try? container.decodeIfPresent(Double.self, forKey: .inTangent)) ?? (try? container.decodeIfPresent(Double.self, forKey: .intangent))
        outTangent = (try? container.decodeIfPresent(Double.self, forKey: .outTangent)) ?? (try? container.decodeIfPresent(Double.self, forKey: .outtangent))
    }
}

private struct WEAnimatedScalar: Decodable {
    let script: String?
    @WEFlexibleDouble var value: Double?
    let animation: WEKeyframeAnimation?
}

private struct FlexibleScriptValue: Decodable {
    let stringValue: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) { stringValue = string }
        else if let number = try? container.decode(Double.self) { stringValue = String(number) }
        else if let bool = try? container.decode(Bool.self) { stringValue = bool ? "true" : "false" }
        else { stringValue = "" }
    }
}

private struct WEScriptedProperty: Decodable {
    let script: String?
    let stringValue: String?
    let vectorAnimation: WEVectorKeyframeAnimation?
    let scriptProperties: [String: String]

    enum CodingKeys: String, CodingKey { case script, value, animation, scriptproperties }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        script = try container.decodeIfPresent(String.self, forKey: .script)
        vectorAnimation = try? container.decodeIfPresent(WEVectorKeyframeAnimation.self, forKey: .animation)
        scriptProperties = (try? container.decode([String: FlexibleScriptValue].self, forKey: .scriptproperties))?
            .mapValues(\.stringValue) ?? [:]
        if let string = try? container.decode(String.self, forKey: .value) {
            stringValue = string
        } else if let number = try? container.decode(Double.self, forKey: .value) {
            stringValue = String(number)
        } else {
            stringValue = nil
        }
    }
}

struct WEInstanceOverride: Codable {
    @WEFlexibleInt var id: Int?
    var colorn: String?
    var rate: WEScriptValue?
    @WEFlexibleDouble var size: Double?
}

struct WEScriptValue: Codable {
    var script: String?
    var value: Double?

    init(from decoder: Decoder) throws {
        // Can be just a number or an object with script+value
        if let container = try? decoder.singleValueContainer(),
           let num = try? container.decode(Double.self) {
            self.value = num
            self.script = nil
        } else if let container = try? decoder.singleValueContainer(),
                  let string = try? container.decode(String.self),
                  let num = Double(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
            self.value = num
            self.script = nil
        } else {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.script = try container.decodeIfPresent(String.self, forKey: .script)
            self.value = try container.decodeIfPresent(Double.self, forKey: .value)
                ?? container.decodeIfPresent(String.self, forKey: .value).flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
    }

    enum CodingKeys: String, CodingKey {
        case script, value
    }
}

// MARK: - Model / Material

struct WEModel: Codable {
    var autosize: Bool?
    var material: String?    // path to material JSON
    var puppet: String?      // path to a Puppet Warp rig (.mdl); unsupported, rendered as a flat atlas otherwise
}

struct WEMaterial: Decodable {
    var passes: [WEMaterialPass]?
}

struct WEMaterialPass: Decodable {
    var blending: String?    // "translucent", "additive"
    var shader: String?
    var textures: [String]?
    var cullmode: String?
    var depthtest: String?
    var depthwrite: String?
    var constants: [String: WEScriptValue]?

    enum CodingKeys: String, CodingKey {
        case blending, shader, textures, cullmode, depthtest, depthwrite, constants, constantshadervalues
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        blending = try container.decodeIfPresent(String.self, forKey: .blending)
        shader = try container.decodeIfPresent(String.self, forKey: .shader)
        textures = try container.decodeIfPresent([String].self, forKey: .textures)
        cullmode = try container.decodeIfPresent(String.self, forKey: .cullmode)
        depthtest = try container.decodeIfPresent(String.self, forKey: .depthtest)
        depthwrite = try container.decodeIfPresent(String.self, forKey: .depthwrite)
        constants = try container.decodeIfPresent([String: WEScriptValue].self, forKey: .constants)
            ?? container.decodeIfPresent([String: WEScriptValue].self, forKey: .constantshadervalues)
    }
}

// MARK: - Particle System

@propertyWrapper
struct WEFlexibleDouble: Codable {
    var wrappedValue: Double?
    var script: String?
    var projectedValue: WEFlexibleDouble { self }

    init(wrappedValue: Double? = nil) {
        self.wrappedValue = wrappedValue
        self.script = nil
    }

    init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: CodingKeys.self) {
            wrappedValue = (try? keyed.decodeIfPresent(Double.self, forKey: .value))
                ?? (try? keyed.decodeIfPresent(String.self, forKey: .value)).flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            script = try? keyed.decodeIfPresent(String.self, forKey: .script)
        } else {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self) {
                wrappedValue = number
            } else if let string = try? container.decode(String.self) {
                wrappedValue = Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                wrappedValue = nil
            }
            script = nil
        }
    }

    private enum CodingKeys: String, CodingKey { case value, script }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

@propertyWrapper
struct WEFlexibleInt: Codable {
    var wrappedValue: Int?

    init(wrappedValue: Int? = nil) {
        self.wrappedValue = wrappedValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int.self) {
            wrappedValue = number
        } else if let string = try? container.decode(String.self) {
            wrappedValue = Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            wrappedValue = nil
        }
    }
}

extension KeyedDecodingContainer {
    func decode(_ type: WEFlexibleDouble.Type, forKey key: Key) throws -> WEFlexibleDouble {
        try decodeIfPresent(type, forKey: key) ?? WEFlexibleDouble()
    }

    func decode(_ type: WEFlexibleInt.Type, forKey key: Key) throws -> WEFlexibleInt {
        try decodeIfPresent(type, forKey: key) ?? WEFlexibleInt()
    }
}

struct WEParticleSystem: Codable {
    var emitter: [WEParticleEmitter]?
    var initializer: [WEParticleInitializer]?
    var `operator`: [WEParticleOperator]?
    var renderer: [WEParticleRenderer]?
    var material: String?
    @WEFlexibleInt var maxcount: Int?
    @WEFlexibleInt var flags: Int?
    @WEFlexibleDouble var starttime: Double?
    var animationmode: String?
    @WEFlexibleDouble var sequencemultiplier: Double?
    var controlpoint: [WEParticleControlPoint]?
}

struct WEParticleEmitter: Codable {
    @WEFlexibleInt var id: Int?
    var name: String?
    @WEFlexibleDouble var rate: Double?
    var origin: String?
    var directions: String?
    var distancemax: WEFlexValue?
    var distancemin: WEFlexValue?
    @WEFlexibleDouble var speedmax: Double?
    @WEFlexibleDouble var speedmin: Double?
    @WEFlexibleInt var controlpoint: Int?
}

struct WEParticleControlPoint: Codable {
    @WEFlexibleInt var id: Int?
    @WEFlexibleInt var flags: Int?
    var offset: String?
    var locktopointer: Bool?
    @WEFlexibleInt var parentcontrolpoint: Int?
}

struct WEParticleInitializer: Codable {
    @WEFlexibleInt var id: Int?
    var name: String?
    var min: WEFlexValue?
    var max: WEFlexValue?
    @WEFlexibleInt var flags: Int?
    @WEFlexibleDouble var count: Double?
    @WEFlexibleDouble var arcamount: Double?
    var limitbehavior: String?
    var axis: String?
    var bounds: String?
    @WEFlexibleInt var controlpoint0: Int?
    @WEFlexibleInt var controlpoint1: Int?
    var speedmin: WEFlexValue?
    var speedmax: WEFlexValue?
    var input: String?
    var output: String?
    var operation: String?
    @WEFlexibleInt var inputcontrolpoint0: Int?
    @WEFlexibleDouble var inputrangemin: Double?
    @WEFlexibleDouble var inputrangemax: Double?
}

/// A value that can be either a number or a string (e.g. "0 -3000 0")
enum WEFlexValue: Codable {
    case number(Double)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let num = try? container.decode(Double.self) {
            self = .number(num)
        } else if let str = try? container.decode(String.self) {
            self = .string(str)
        } else {
            self = .number(0)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let n): try container.encode(n)
        case .string(let s): try container.encode(s)
        }
    }

    var doubleValue: Double {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s) ?? 0
        }
    }

    var vectorValue: (Double, Double, Double) {
        switch self {
        case .number(let n): return (n, n, n)
        case .string(let s): return s.parseVector3()
        }
    }
}

struct WEParticleOperator: Codable {
    @WEFlexibleInt var id: Int?
    var name: String?
    var gravity: String?
    @WEFlexibleDouble var drag: Double?
    @WEFlexibleDouble var fadeintime: Double?
    @WEFlexibleDouble var fadeouttime: Double?
    var scale: WEFlexValue?
    @WEFlexibleDouble var speedmin: Double?
    @WEFlexibleDouble var speedmax: Double?
    @WEFlexibleDouble var timescale: Double?
    var mask: WEFlexValue?
    @WEFlexibleDouble var phasemin: Double?
    @WEFlexibleDouble var phasemax: Double?
    @WEFlexibleInt var controlpoint: Int?
    var origin: WEFlexValue?
    @WEFlexibleDouble var threshold: Double?
    @WEFlexibleDouble var starttime: Double?
    @WEFlexibleDouble var endtime: Double?
    var startvalue: WEFlexValue?
    var endvalue: WEFlexValue?
    var force: String?
    var axis: String?
    @WEFlexibleDouble var distanceinner: Double?
    @WEFlexibleDouble var distanceouter: Double?
    @WEFlexibleDouble var speedinner: Double?
    @WEFlexibleDouble var speedouter: Double?
    @WEFlexibleDouble var maxspeed: Double?
    @WEFlexibleDouble var ringradius: Double?
    @WEFlexibleDouble var ringwidth: Double?
    @WEFlexibleDouble var ringpulldistance: Double?
    @WEFlexibleDouble var alignmentfactor: Double?
    @WEFlexibleDouble var cohesionfactor: Double?
    @WEFlexibleDouble var separationfactor: Double?
    @WEFlexibleDouble var neighborthreshold: Double?
    @WEFlexibleDouble var frequencymin: Double?
    @WEFlexibleDouble var frequencymax: Double?
    @WEFlexibleDouble var scalemin: Double?
    @WEFlexibleDouble var scalemax: Double?
    @WEFlexibleDouble var reductioninner: Double?
    @WEFlexibleDouble var variablestrength: Double?
    var input: String?
    var output: String?
    var operation: String?
    var transformfunction: String?
    @WEFlexibleDouble var transforminputscale: Double?
    var outputrangemin: WEFlexValue?
    var outputrangemax: WEFlexValue?
    @WEFlexibleInt var controlpoint0: Int?
    @WEFlexibleInt var controlpoint1: Int?
}

struct WEParticleRenderer: Codable {
    @WEFlexibleInt var id: Int?
    var name: String?       // "sprite", "spritetrail"
    @WEFlexibleDouble var length: Double?
    @WEFlexibleDouble var maxlength: Double?
    @WEFlexibleDouble var minlength: Double?
    @WEFlexibleInt var segments: Int?
    @WEFlexibleInt var subdivision: Int?
    var fadealpha: Bool?
    var fadesize: Bool?
}

// MARK: - String Parsing Helpers

extension String {
    /// Parse "x y z" space-separated vector string
    func parseVector3() -> (Double, Double, Double) {
        let parts = self.split(separator: " ").compactMap { Double($0) }
        return (
            parts.count > 0 ? parts[0] : 0,
            parts.count > 1 ? parts[1] : 0,
            parts.count > 2 ? parts[2] : 0
        )
    }

    /// Parse "x y" space-separated 2D vector
    func parseVector2() -> (Double, Double) {
        let parts = self.split(separator: " ").compactMap { Double($0) }
        return (
            parts.count > 0 ? parts[0] : 0,
            parts.count > 1 ? parts[1] : 0
        )
    }

    /// Parse "r g b" color string (0-1 range) to NSColor
    func parseColor() -> (r: Double, g: Double, b: Double) {
        let v = self.parseVector3()
        return (r: v.0, g: v.1, b: v.2)
    }
}
