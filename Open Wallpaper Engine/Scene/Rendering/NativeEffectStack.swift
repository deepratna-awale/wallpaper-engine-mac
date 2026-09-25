import Cocoa
import MetalKit
import CryptoKit

struct EffectStack {
    let descriptors: [EffectDescriptorGPU]

    /// maskSlots maps each entry in `effects` to the bound mask texture slot (0...3) prepared for this
    /// layer, or nil if it has no mask. Pass an empty array to render every effect unmasked.
    init(effects: [SceneMetalEffect], maskSlots: [Int?] = [], blendSlots: [Int?] = [],
         globalNames: Set<String>, sceneSize: SIMD2<Float>, audioLevel: Float) {
        var descriptors: [EffectDescriptorGPU] = []
        for (index, effect) in effects.enumerated() {
            let slot = index < maskSlots.count ? maskSlots[index] : nil
            let maskIndex = slot.map(UInt32.init) ?? UInt32.max
            guard var descriptor = Self.descriptor(for: effect, maskIndex: maskIndex, sceneSize: sceneSize,
                                                   audioLevel: audioLevel, useUserOverrides: false) else { continue }
            if effect.blend != nil {
                // Only the blend effect reads `extra`; every other kind packs its own values there.
                descriptor.extra.x = Float(index < blendSlots.count ? (blendSlots[index] ?? -1) : -1)
                descriptor.extra.y = Float(effect.blendMode)
            }
            descriptors.append(descriptor)
        }
        for name in globalNames {
            guard Self.isEnabled(name) else { continue }
            guard let descriptor = Self.descriptor(for: SceneMetalEffect(name: name, constants: [:], mask: nil, scripts: [:]),
                                                   maskIndex: UInt32.max, sceneSize: sceneSize,
                                                   audioLevel: audioLevel, useUserOverrides: true) else { continue }
            descriptors.append(descriptor)
        }
        self.descriptors = descriptors.isEmpty ? [EffectDescriptorGPU(kind: 0, maskIndex: UInt32.max, values: .zero, extra: .zero)] : descriptors
    }

    private static func isEnabled(_ name: String) -> Bool {
        if name == "audiobars" {
            return AudioReactiveScriptEngine.shared.userPropertyString("_owe_effect_enabled_\(name)") != "false"
                && AudioReactiveScriptEngine.shared.userPropertyString("audiovisualizer") != "false"
        }
        return AudioReactiveScriptEngine.shared.userPropertyString("_owe_effect_enabled_\(name)") != "false"
    }

    /// Effects whose descriptor bakes the raw audio level, so they cannot be cached across frames.
    /// Audio-bar/hue/hyperdrive are absent on purpose: they read audio in the shader via the
    /// audioBands uniform, so their descriptors only change when user properties do.
    private static let audioBakedEffects: Set<String> = ["shake", "pulse"]

    static func isFrameVarying(effects: [SceneMetalEffect], globalNames: Set<String>) -> Bool {
        if effects.contains(where: { !$0.scripts.isEmpty }) { return true }
        if effects.contains(where: { audioBakedEffects.contains($0.name) }) { return true }
        // Music-synced authored parameters change every frame, so their descriptors cannot cache.
        if effects.contains(where: { effect in
            effect.overrideKeys.values.contains { keys in
                keys.contains { AudioReactiveScriptEngine.shared.isMusicSynced($0) }
            }
        }) { return true }
        return globalNames.contains(where: { audioBakedEffects.contains($0) })
    }

    func bind(to encoder: MTLRenderCommandEncoder) {
        var count = UInt32(descriptors.count)
        descriptors.withUnsafeBufferPointer { buffer in
            encoder.setVertexBytes(buffer.baseAddress!, length: MemoryLayout<EffectDescriptorGPU>.stride * descriptors.count, index: 2)
            encoder.setFragmentBytes(buffer.baseAddress!, length: MemoryLayout<EffectDescriptorGPU>.stride * descriptors.count, index: 2)
        }
        encoder.setVertexBytes(&count, length: MemoryLayout<UInt32>.stride, index: 3)
        encoder.setFragmentBytes(&count, length: MemoryLayout<UInt32>.stride, index: 3)
    }

    private static func descriptor(for effect: SceneMetalEffect, maskIndex: UInt32,
                                   sceneSize: SIMD2<Float>, audioLevel: Float,
                                   useUserOverrides: Bool) -> EffectDescriptorGPU? {
        // Authored values live in Wallpaper Engine's per-parameter range; our own sliders already
        // store values in this build's range, so only the former are translated.
        let translate = { (name: String, raw: Float) -> Float in
            SceneAuthoredEffectRanges.translate(effect: effect.name, key: name, authored: raw) ?? raw
        }
        let value = { (name: String, fallback: Float) in
            let authored = effect.constants[name]?.first ?? fallback
            if let script = effect.scripts[name] {
                return translate(name, AudioReactiveScriptEngine.shared.evaluate(script, fallback: authored))
            }
            if let componentKey = effect.overrideKeys[name]?.first {
                return translate(name, AudioReactiveScriptEngine.shared.userPropertyValue(componentKey, fallback: authored))
            }
            let base = translate(name, authored)
            guard useUserOverrides || ["audiobars", "hueshift", "hyperdrive"].contains(effect.name) else { return base }
            return AudioReactiveScriptEngine.shared.userPropertyValue("_owe_effect_\(effect.name)_\(name)", fallback: base)
        }
        let zeroDisablesKeys = ["strength", "intensity", "amount", "alpha", "density",
                                "multiply", "rayintensity", "colorwintensity", "ripplestrength"]
        if effect.name == "audiobars" {
            guard AudioReactiveScriptEngine.shared.userPropertyString("_owe_effect_enabled_audiobars") != "false",
                  AudioReactiveScriptEngine.shared.userPropertyString("audiovisualizer") != "false" else { return nil }
        }
        if zeroDisablesKeys.contains(where: { key in
            guard effect.constants[key] != nil || effect.scripts[key] != nil || useUserOverrides else { return false }
            return value(key, 1) <= 0.0001
        }) {
            return nil
        }
        let vector = { (name: String, fallback: SIMD4<Float>) -> SIMD4<Float> in
            let values = effect.constants[name] ?? []
            guard !values.isEmpty else { return fallback }
            let keys = effect.overrideKeys[name] ?? []
            var resolved = SIMD4<Float>(repeating: 0)
            for index in 0..<min(4, values.count) {
                resolved[index] = index < keys.count
                    ? AudioReactiveScriptEngine.shared.userPropertyValue(keys[index], fallback: values[index])
                    : values[index]
            }
            return resolved
        }
        switch effect.name {
        case "shake":
            return EffectDescriptorGPU(kind: 1, maskIndex: maskIndex,
                                       values: SIMD4(value("strength", 0.1), value("speed", 1), value("friction", 1), audioLevel), extra: .zero)
        case "waterwaves":
            return EffectDescriptorGPU(kind: 2, maskIndex: maskIndex,
                                       values: SIMD4(value("strength", 0.1), value("speed", 5), value("scale", 200), value("direction", 0)),
                                       extra: SIMD4(value("exponent", 1), 0, 0, 0))
        case "nitro":
            let speeds = vector("speed", SIMD4(-0.1, 0.7, 0.1, -0.5))
            let scales = vector("scale", SIMD4(1, 2, 0, 0))
            let bounds = vector("bounds", SIMD4(0.3, 0.25, 0, 0))
            let colorStart = vector("colorstart", SIMD4(0.247, 0.478, 0.682, 0))
            let colorEnd = vector("colorend", SIMD4(0.376, 0.568, 0.745, 0))
            return EffectDescriptorGPU(kind: 3, maskIndex: maskIndex,
                                       values: SIMD4(value("multiply", 1), speeds.x, speeds.y, speeds.z), extra: SIMD4(speeds.w, scales.x, scales.y, bounds.x),
                                       extra2: SIMD4(colorStart.x, colorStart.y, colorStart.z, value("smoothness", 1)),
                                       extra3: SIMD4(colorEnd.x, colorEnd.y, colorEnd.z, bounds.y))
        case "vhs":
            return EffectDescriptorGPU(kind: 4, maskIndex: maskIndex,
                                       values: SIMD4(value("strength", 1.2), value("chromatic", 0.1), value("artifacts", 0.5), value("distortionstrength", 1)),
                                       extra: SIMD4(value("distortionspeed", 1), value("distortionwidth", 1), 0, 0))
        case "pulse":
            return EffectDescriptorGPU(kind: 5, maskIndex: maskIndex, values: SIMD4(audioLevel, 0, 0, 0), extra: .zero)
        case "audiobars":
            return EffectDescriptorGPU(kind: 47, maskIndex: maskIndex,
                                       values: SIMD4(value("opacity", 1), value("strength", 2.2), value("bars", 16), value("minimum", 0.02)),
                                       extra: SIMD4(value("red", 0.35), value("green", 0.85), value("blue", 1), value("glow", 0.35)),
                                       extra2: SIMD4(value("gap", 0.5), value("smoothing", 0.72), 0, 0))
        case "hueshift":
            let bounds = vector("audiobounds", SIMD4(0.5, 1.0, 0, 0))
            return EffectDescriptorGPU(kind: 48, maskIndex: maskIndex,
                                       values: SIMD4(value("audioamount", 0.2), value("audioexponent", 0.2), value("frequencymin", 4), value("frequencymax", 7)),
                                       extra: SIMD4(bounds.x, bounds.y, value("intensity", 1), 0))
        case "hyperdrive":
            let bounds = vector("audiobounds", SIMD4(0.0, 1.2, 0, 0))
            return EffectDescriptorGPU(kind: 49, maskIndex: maskIndex,
                                       values: SIMD4(value("audioamount", 1), value("audioexponent", 1), value("frequencymin", 0), value("frequencymax", 1)),
                                       extra: SIMD4(bounds.x, bounds.y, value("strength", 1), value("speed", 1)))
        case "iris":
            return EffectDescriptorGPU(kind: 6, maskIndex: maskIndex, values: SIMD4(1, 0, 0, 0), extra: .zero)
        case "volumetricfog":
            return EffectDescriptorGPU(kind: 7, maskIndex: maskIndex,
                                       values: SIMD4(value("density", 0.65), value("drift", 0.035), 0.12, 0.8),
                                       extra: SIMD4(value("near", 0.45), value("far", 0.85), 0, 0))
        case "foliagesway":
            return EffectDescriptorGPU(kind: 8, maskIndex: maskIndex,
                                       values: SIMD4(value("strength", 0.4), value("scale", 0.05), value("speeduv", 5), value("phase", 0)),
                                       extra: SIMD4(value("power", 1), value("ratio", 0.3), 0, 0))
        case "waterripple":
            return EffectDescriptorGPU(kind: 9, maskIndex: maskIndex,
                                       values: SIMD4(value("ripplestrength", 0.06), value("scale", 0.58), value("animationspeed", 0.15), value("scrolldirection", 0)),
                                       extra: SIMD4(value("scrollspeed", 0), value("ratio", 0.63), 0, 0))
        case "godrays":
            let center = vector("center", SIMD4(0.5, 0.5, 0, 0))
            return EffectDescriptorGPU(kind: 10, maskIndex: maskIndex,
                                       values: SIMD4(value("raythreshold", 0.86), value("rayintensity", 0.77), value("raylength", 0.49), value("noisespeed", 0.15)),
                                       extra: SIMD4(value("noiseamount", 0.91), value("noisescale", 3), center.x, center.y))
        case "lightshafts":
            let colorEnd = vector("colorend", SIMD4(1, 1, 1, 0))
            if useUserOverrides {
                return EffectDescriptorGPU(kind: 50, maskIndex: maskIndex,
                                           values: SIMD4(value("colorwintensity", 0.45), value("rayspeed", 0.39), value("rayradius", 0.15), value("noiseamount", 0.33)),
                                           extra: SIMD4(value("noisescale", 0.85), 0, 0, 0),
                                           extra2: SIMD4(colorEnd.x, colorEnd.y, colorEnd.z, 0))
            }
            return EffectDescriptorGPU(kind: 11, maskIndex: maskIndex,
                                       values: SIMD4(value("rayradius", 0.15), value("rayspeed", 0.39), value("raysmoothness", 0.54), value("noiseamount", 0.33)),
                                       extra: SIMD4(value("noisescale", 0.85), value("colorwintensity", 0.45), 0, 0),
                                       extra2: SIMD4(colorEnd.x, colorEnd.y, colorEnd.z, 0))
        case "tint":
            let color = vector("color", SIMD4(1, 1, 1, 1))
            return EffectDescriptorGPU(kind: 12, maskIndex: maskIndex,
                                       values: SIMD4(color.x, color.y, color.z, value("alpha", 1)), extra: .zero)
        case "opacity":
            return EffectDescriptorGPU(kind: 13, maskIndex: maskIndex,
                                       values: SIMD4(value("alpha", 1), 0, 0, 0), extra: .zero)
        case "fisheye":
            let center = vector("center", SIMD4(0.5, 0.5, 0, 0))
            return EffectDescriptorGPU(kind: 14, maskIndex: maskIndex,
                                       values: SIMD4(value("size", 1), value("scale", 1), center.x, center.y), extra: .zero)
        case "scroll":
            return EffectDescriptorGPU(kind: 15, maskIndex: maskIndex,
                                       values: SIMD4(value("speedx", 0.2), value("speedy", 0.2), value("repeatx", 1), value("repeaty", 1)), extra: .zero)
        case "chromaticaberration":
            let center = vector("center", SIMD4(0.5, 0.5, 0, 0))
            return EffectDescriptorGPU(kind: 16, maskIndex: maskIndex,
                                       values: SIMD4(value("direction", Float.pi / 2), value("strength", 1), value("centerfalloff", 1), 0),
                                       extra: SIMD4(center.x, center.y, 0, 0))
        case "spin":
            let center = vector("center", SIMD4(0.5, 0.5, 0, 0))
            return EffectDescriptorGPU(kind: 17, maskIndex: maskIndex,
                                       values: SIMD4(value("size", 0.1), value("feather", 0.002), center.x, center.y), extra: .zero)
        case "colorkey":
            let color = vector("color", SIMD4(1, 1, 1, 0))
            return EffectDescriptorGPU(kind: 18, maskIndex: maskIndex,
                                       values: SIMD4(value("alpha", 0), value("fuzziness", 0), value("tolerance", 0.1), 0),
                                       extra: SIMD4(color.x, color.y, color.z, 0))
                        case "blur": return EffectDescriptorGPU(kind: 36, maskIndex: maskIndex, values: SIMD4(value("amount", 0.25), 0, 0, 0), extra: .zero)
                        case "blurprecise": return EffectDescriptorGPU(kind: 37, maskIndex: maskIndex, values: SIMD4(value("amount", 0.35), 0, 0, 0), extra: .zero)
                        case "cursorripple": return EffectDescriptorGPU(kind: 38, maskIndex: maskIndex, values: SIMD4(value("amount", 0.04), value("speed", 1), 0, 0), extra: .zero)
                        case "glitter": return EffectDescriptorGPU(kind: 39, maskIndex: maskIndex, values: SIMD4(value("amount", 0.35), value("speed", 1), 0, 0), extra: .zero)
                        case "localcontrast": return EffectDescriptorGPU(kind: 40, maskIndex: maskIndex, values: SIMD4(value("amount", 0.5), 0, 0, 0), extra: .zero)
                        case "motionblur": return EffectDescriptorGPU(kind: 41, maskIndex: maskIndex, values: SIMD4(value("amount", 0.2), value("speed", 1), 0, 0), extra: .zero)
                        case "refraction": return EffectDescriptorGPU(kind: 42, maskIndex: maskIndex, values: SIMD4(value("amount", 0.04), value("speed", 1), 0, 0), extra: .zero)
                        case "shine": return EffectDescriptorGPU(kind: 43, maskIndex: maskIndex, values: SIMD4(value("amount", 0.5), value("speed", 1), 0, 0), extra: .zero)
                        case "empty": return EffectDescriptorGPU(kind: 44, maskIndex: maskIndex, values: .zero, extra: .zero)
                        case "shimmer": return EffectDescriptorGPU(kind: 45, maskIndex: maskIndex, values: SIMD4(value("amount", 0.35), value("speed", 1), 0, 0), extra: .zero)
                        // Wallpaper Engine names the blend strength "multiply"; it is commonly
                        // script-driven (e.g. time of day), so it has to stay a live value.
                        case "blend": return EffectDescriptorGPU(kind: 19, maskIndex: maskIndex,
                                                                 values: SIMD4(value("multiply", value("amount", 1)), 0, 0, 0),
                                                                 extra: .zero)
                        case "blendgradient": return EffectDescriptorGPU(kind: 20, maskIndex: maskIndex, values: SIMD4(value("amount", 1), 0, 0, 0), extra: .zero)
                        case "blurradial": return EffectDescriptorGPU(kind: 21, maskIndex: maskIndex, values: SIMD4(value("amount", 0.25), 0, 0, 0), extra: .zero)
                        case "watercaustics": return EffectDescriptorGPU(kind: 22, maskIndex: maskIndex, values: SIMD4(value("amount", 0.15), value("speed", 1), 0, 0), extra: .zero)
                        case "cloudmotion": return EffectDescriptorGPU(kind: 23, maskIndex: maskIndex, values: SIMD4(value("amount", 0.08), value("speed", 0.2), 0, 0), extra: .zero)
                        case "clouds": return EffectDescriptorGPU(kind: 24, maskIndex: maskIndex, values: SIMD4(value("amount", 0.2), value("speed", 0.2), 0, 0), extra: .zero)
                        case "edgedetection": return EffectDescriptorGPU(kind: 25, maskIndex: maskIndex, values: SIMD4(value("amount", 1), 0, 0, 0), extra: .zero)
                        case "filmgrain": return EffectDescriptorGPU(kind: 26, maskIndex: maskIndex, values: SIMD4(value("amount", 0.08), value("speed", 1), 0, 0), extra: .zero)
                        case "fire": return EffectDescriptorGPU(kind: 27, maskIndex: maskIndex, values: SIMD4(value("amount", 0.15), value("speed", 1), 0, 0), extra: .zero)
                        case "perspective": return EffectDescriptorGPU(kind: 28, maskIndex: maskIndex, values: SIMD4(value("amount", 0.1), 0, 0, 0), extra: .zero)
                        case "depthparallax":
                            let center = vector("center", SIMD4(0.5, 0.5, 0, 0))
                            return EffectDescriptorGPU(kind: 46, maskIndex: maskIndex,
                                                       values: SIMD4(value("depthx", 0.1), value("depthy", 0.1), value("perspective", 0.2), 0),
                                                       extra: SIMD4(center.x, center.y, 0, 0))
                        case "reflection": return EffectDescriptorGPU(kind: 29, maskIndex: maskIndex, values: SIMD4(value("amount", 0.2), 0, 0, 0), extra: .zero)
                        case "skew": return EffectDescriptorGPU(kind: 30, maskIndex: maskIndex, values: SIMD4(value("amount", 0.05), value("speed", 1), 0, 0), extra: .zero)
                        case "swing": return EffectDescriptorGPU(kind: 31, maskIndex: maskIndex, values: SIMD4(value("amount", 0.05), value("speed", 1), 0, 0), extra: .zero)
                        case "transform": return EffectDescriptorGPU(kind: 32, maskIndex: maskIndex, values: SIMD4(value("amount", 0), 0, 0, 0), extra: .zero)
                        case "twirl": return EffectDescriptorGPU(kind: 33, maskIndex: maskIndex, values: SIMD4(value("amount", 0.2), value("speed", 0.2), 0.5, 0.5), extra: .zero)
                        case "waterflow": return EffectDescriptorGPU(kind: 34, maskIndex: maskIndex, values: SIMD4(value("amount", 0.08), value("speed", 0.2), 0, 0), extra: .zero)
                        case "xray": return EffectDescriptorGPU(kind: 35, maskIndex: maskIndex, values: SIMD4(value("size", 0.55), 0, 0, 0), extra: .zero)
        default:
            return nil
        }
    }
}
