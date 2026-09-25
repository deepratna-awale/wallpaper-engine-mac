import Foundation

/// Many WE scene fields can be either a plain value or a {"script":"..","value":..} object.
/// This wrapper decodes the plain value and silently ignores script objects.
func decodeFlexible<T: Decodable>(_ type: T.Type, container: KeyedDecodingContainer<WESceneObject.CodingKeys>, key: WESceneObject.CodingKeys) -> T? {
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
    /// Dynamic screen anchor: none, center, top, topright, …
    var anchor: String?
    var blockalign: Bool?

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
        case padding, maxwidth, maxrows, limitwidth, limitrows, limituseellipsis, anchor, blockalign
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
        effects = c.decodeElements(WEObjectEffect.self, forKey: .effects, userInfo: decoder.userInfo)
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
        anchor = try? c.decodeIfPresent(String.self, forKey: .anchor)
        blockalign = try? c.decodeIfPresent(Bool.self, forKey: .blockalign)

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

/// An effect instance on a scene object. `passes` holds every authored pass, in order.
struct WEObjectEffect: Decodable {
    let file: String
    let id: Int?
    let name: String?
    let visible: Bool?
    let visibleCondition: String?
    let visibleUserProperty: String?
    let visibleScript: String?
    let passes: [WEObjectEffectPass]?

    enum CodingKeys: String, CodingKey { case file, id, name, visible, passes }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let info = decoder.userInfo
        file = try container.decode(String.self, forKey: .file)
        id = container.decodeLogged(Int.self, forKey: .id, userInfo: info)
        name = container.decodeLogged(String.self, forKey: .name, userInfo: info)
        switch container.decodeLogged(SceneJSON.self, forKey: .visible, userInfo: info) {
        case .object?:
            let conditional = container.decodeLogged(WEConditionalBool.self, forKey: .visible, userInfo: info)
            visible = conditional?.value
            visibleCondition = conditional?.condition
            visibleUserProperty = conditional?.property
            visibleScript = conditional?.script
        case .bool(let flag)?:
            (visible, visibleCondition, visibleUserProperty, visibleScript) = (flag, nil, nil, nil)
        case .number(let number)?:
            (visible, visibleCondition, visibleUserProperty, visibleScript) = (number != 0, nil, nil, nil)
        case .string(let text)?:
            (visible, visibleCondition, visibleUserProperty, visibleScript) = (!["false", "0"].contains(text.lowercased()), nil, nil, nil)
        default:
            (visible, visibleCondition, visibleUserProperty, visibleScript) = (nil, nil, nil, nil)
        }
        passes = container.decodeElements(WEObjectEffectPass.self, forKey: .passes, userInfo: info)
    }
}

/// Per-instance overrides for one pass of an effect.
struct WEObjectEffectPass: Decodable {
    /// Legacy view of the constants (number/string/script only), used by the current renderer.
    let constantshadervalues: [String: WEEffectConstant]?
    /// Every constant with its full authored form.
    let constants: [String: SceneRawValue]
    /// Texture slots; nil entries are kept so indices match the material.
    let textures: [String?]?
    let combos: [String: Int]?
    /// `usertextures` (e.g. `[null, {"name":"$mediaThumbnail","type":"system"}]`), kept raw.
    let usertextures: SceneJSON?

    enum CodingKeys: String, CodingKey { case constantshadervalues, textures, combos, usertextures }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let info = decoder.userInfo
        constants = c.decodeEntries(SceneRawValue.self, forKey: .constantshadervalues, userInfo: info) ?? [:]
        // Failures are already reported by `constants` above.
        constantshadervalues = try? c.decodeIfPresent([String: WEEffectConstant].self, forKey: .constantshadervalues)
        textures = c.decodeElements(String?.self, forKey: .textures, userInfo: info)
        combos = c.decodeEntries(Int.self, forKey: .combos, userInfo: info)
        usertextures = c.decodeLogged(SceneJSON.self, forKey: .usertextures, userInfo: info)
    }
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

struct WEConditionalBool: Decodable {
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

struct WEAnimatedScalar: Decodable {
    let script: String?
    @WEFlexibleDouble var value: Double?
    let animation: WEKeyframeAnimation?
}

struct FlexibleScriptValue: Decodable {
    let stringValue: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) { stringValue = string }
        else if let number = try? container.decode(Double.self) { stringValue = String(number) }
        else if let bool = try? container.decode(Bool.self) { stringValue = bool ? "true" : "false" }
        else { stringValue = "" }
    }
}

struct WEScriptedProperty: Decodable {
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
