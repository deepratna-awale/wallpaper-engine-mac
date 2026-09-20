import CoreMedia
import ScreenCaptureKit
import Accelerate
import JavaScriptCore

extension Notification.Name {
    static let sceneUserPropertiesDidChange = Notification.Name("SceneUserPropertiesDidChange")
}

final class AudioReactiveScriptEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    static let shared = AudioReactiveScriptEngine()
    private static let screenCapturePromptedKey = "ScreenCapturePermissionPrompted"

    /// WE scripts are authored as ES modules (`export function update`, `export let __workshopId`, etc.),
    /// but JSContext.evaluateScript runs plain (non-module) scripts, where `export` is a syntax error that
    /// silently aborts the whole script under our exception handler. Strip every export keyword so the
    /// declarations still run as ordinary top-level statements.
    private static func stripESModuleExports(_ script: String) -> String {
        script.replacingOccurrences(of: #"(^|\n)\s*export\s+(function|let|const|var|class|default)"#,
                                    with: "$1$2", options: .regularExpression)
    }

    private let levelLock = NSLock()
    private var level: Double = 0
    private var spectrum = [Double](repeating: 0, count: 64)
    private var stream: SCStream?
    private var globalValues: [String: Double] = [:]
    private var userPropertyStrings: [String: String] = [:]
    private var layerStates: [String: [String: Any]] = [:]
    private var layerAliases: [String: String] = [:]
    private var scriptContexts: [String: JSContext] = [:]
    private var returnFunctions: [String: JSValue] = [:]
    private var initializedScripts = Set<String>()
    private let scriptLock = NSLock()
    private var sceneDeltaTime: Double = 1.0 / 60.0
    private var sceneFrame: Int = 0

    private override init() {
        super.init()
        startSystemAudioCapture()
    }

    func configureLayers(_ layers: [String: [String: Any]], aliases: [String: String]) {
        levelLock.lock()
        layerStates = layers
        layerAliases = aliases
        levelLock.unlock()
        scriptLock.lock()
        scriptContexts.removeAll()
        returnFunctions.removeAll()
        initializedScripts.removeAll()
        scriptLock.unlock()
    }

    func setUserProperties(_ values: [String: String]) {
        levelLock.lock()
        for (key, value) in values {
            userPropertyStrings[key] = value
            globalValues[key] = Double(value) ?? (value.lowercased() == "true" ? 1 : 0)
        }
        levelLock.unlock()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .sceneUserPropertiesDidChange, object: nil)
        }
    }

    func setSceneClock(deltaTime: Double) {
        levelLock.lock()
        sceneDeltaTime = max(0, min(deltaTime, 0.25))
        sceneFrame &+= 1
        levelLock.unlock()
    }

    func userPropertyValue(_ key: String, fallback: Float) -> Float {
        levelLock.lock()
        defer { levelLock.unlock() }
        return Float(globalValues[key] ?? Double(fallback))
    }

    func userPropertyString(_ key: String) -> String? {
        levelLock.lock()
        defer { levelLock.unlock() }
        return userPropertyStrings[key]
    }

    func resolveLayerVisibility(_ objects: [WESceneObject], initial: [String: Bool]) -> [String: Bool] {
        levelLock.lock()
        let propertyStrings = userPropertyStrings
        levelLock.unlock()
        return Self.resolveLayerVisibility(objects, initial: initial, userProperties: propertyStrings)
    }

    static func resolveLayerVisibility(_ objects: [WESceneObject], initial: [String: Bool],
                                       userProperties propertyStrings: [String: String]) -> [String: Bool] {
        var states: [String: [String: Any]] = [:]
        var aliases: [String: String] = [:]
        for (index, object) in objects.enumerated() {
            let id = String(object.id ?? index)
            states[id] = ["name": object.name ?? id, "visible": initial[id] ?? true]
            aliases[id] = id
            aliases[String(index)] = id
            if let name = object.name { aliases[name] = id }
        }
        let userProperties = propertyStrings.mapValues { value -> Any in
            if value.caseInsensitiveCompare("true") == .orderedSame { return true }
            if value.caseInsensitiveCompare("false") == .orderedSame { return false }
            return Double(value) ?? value
        }
        guard let context = JSContext() else { return initial }
        context.exceptionHandler = { _, _ in }
        context.setObject(states, forKeyedSubscript: "__layers" as NSString)
        context.setObject(aliases, forKeyedSubscript: "__layerAliases" as NSString)
        context.setObject(["runtime": 0, "userProperties": userProperties], forKeyedSubscript: "engine" as NSString)
        context.evaluateScript("var console = { log: function() {} }; var thisScene = { getLayerCount: function() { return \(objects.count); }, getLayer: function(layer) { var key = String(layer); return __layers[__layerAliases[key] || key]; } };")

        for (index, object) in objects.enumerated() {
            guard let script = object.visibleScript else { continue }
            let id = String(object.id ?? index)
            guard let layer = context.objectForKeyedSubscript("__layers")?.forProperty(id) else { continue }
            context.setObject(layer, forKeyedSubscript: "thisLayer" as NSString)
            context.evaluateScript(Self.stripESModuleExports(script))
            let fallback = initial[id] ?? false
            _ = context.objectForKeyedSubscript("init")?.call(withArguments: [fallback])
            if let result = context.objectForKeyedSubscript("update")?.call(withArguments: [fallback]), !result.isUndefined {
                layer.setValue(result.toBool(), forProperty: "visible")
            }
        }

        guard let resolved = context.objectForKeyedSubscript("__layers")?.toDictionary() as? [String: Any] else { return initial }
        return initial.merging(resolved.compactMapValues { ($0 as? [String: Any])?["visible"] as? Bool }) { _, value in value }
    }

    func layerValue(_ layerId: String, property: String, fallback: Float) -> Float {
        levelLock.lock()
        defer { levelLock.unlock() }
        return (layerStates[layerId]?[property] as? NSNumber)?.floatValue ?? fallback
    }

    func layerVector2(_ layerId: String, property: String, fallback: SIMD2<Float>) -> SIMD2<Float> {
        levelLock.lock()
        defer { levelLock.unlock() }
        guard let value = layerStates[layerId]?[property] as? [String: Any],
              let x = (value["x"] as? NSNumber)?.floatValue,
              let y = (value["y"] as? NSNumber)?.floatValue else { return fallback }
        return SIMD2<Float>(x, y)
    }

    func evaluate(_ script: String, fallback: Float, layerId: String? = nil,
                  time: Double = CACurrentMediaTime()) -> Float {
        let value = evaluateValue(script, input: fallback, layerId: layerId, time: time)
        guard let value, value.isNumber else { return fallback }
        let result = value.toDouble()
        return result.isFinite ? Float(result) : fallback
    }

    func evaluateString(_ script: String, fallback: String, layerId: String? = nil,
                        time: Double = CACurrentMediaTime()) -> String {
        evaluateValue(script, input: fallback, layerId: layerId, time: time)?.toString() ?? fallback
    }

    func evaluateVector2(_ script: String, fallback: SIMD2<Float>, layerId: String? = nil,
                         time: Double = CACurrentMediaTime()) -> SIMD2<Float>? {
        guard let value = evaluateValue(script, input: [fallback.x, fallback.y], layerId: layerId, time: time) else { return nil }
        if value.isObject,
           let x = value.forProperty("x")?.toNumber(), let y = value.forProperty("y")?.toNumber() {
            return SIMD2<Float>(x.floatValue, y.floatValue)
        }
        if let string = value.toString() {
            let vector = string.parseVector2()
            return SIMD2<Float>(Float(vector.0), Float(vector.1))
        }
        return nil
    }

    func evaluateVector3(_ script: String, fallback: SIMD3<Float>, layerId: String? = nil,
                         time: Double = CACurrentMediaTime()) -> SIMD3<Float>? {
        guard let value = evaluateValue(script, input: [fallback.x, fallback.y, fallback.z], layerId: layerId, time: time) else { return nil }
        if value.isObject,
           let x = value.forProperty("x")?.toNumber(), let y = value.forProperty("y")?.toNumber(),
           let z = value.forProperty("z")?.toNumber() {
            return SIMD3<Float>(x.floatValue, y.floatValue, z.floatValue)
        }
        if let string = value.toString() {
            let vector = string.parseVector3()
            return SIMD3<Float>(Float(vector.0), Float(vector.1), Float(vector.2))
        }
        return nil
    }

    private func evaluateValue(_ script: String, input: Any, layerId: String?, time: Double) -> JSValue? {
        let contextKey = "\(layerId ?? "global"):\(script)"
        scriptLock.lock()
        let context = scriptContexts[contextKey] ?? JSContext()
        scriptContexts[contextKey] = context
        scriptLock.unlock()
        context?.exceptionHandler = { _, _ in }
        let currentLevel = audioLevel
        let currentSpectrum = audioSpectrum
        let audioBlock: @convention(block) (Double, Double) -> Double = { low, high in
            let minimum = max(0, min(63, Int(low)))
            let maximum = max(minimum, min(63, Int(high)))
            return currentSpectrum[minimum...maximum].max() ?? currentLevel
        }
        let fftBlock: @convention(block) (Double) -> Double = { index in
            currentSpectrum[max(0, min(63, Int(index)))]
        }
        let propertyBlock: @convention(block) (String) -> Double = { [weak self] name in
            self?.levelLock.lock()
            defer { self?.levelLock.unlock() }
            return self?.globalValues[name] ?? 0
        }
        let setGlobalBlock: @convention(block) (String, Double) -> Void = { [weak self] name, value in
            self?.levelLock.lock()
            self?.globalValues[name] = value
            self?.levelLock.unlock()
        }
        context?.setObject(audioBlock, forKeyedSubscript: "audio" as NSString)
        context?.setObject(fftBlock, forKeyedSubscript: "fft" as NSString)
        context?.setObject(propertyBlock, forKeyedSubscript: "property" as NSString)
        context?.setObject(setGlobalBlock, forKeyedSubscript: "setGlobal" as NSString)
        context?.setObject(time, forKeyedSubscript: "time" as NSString)
        let cursor = ["x": NSEvent.mouseLocation.x, "y": NSEvent.mouseLocation.y]
        context?.setObject(cursor, forKeyedSubscript: "cursor" as NSString)
        let mouseButtons = NSEvent.pressedMouseButtons
        let modifiers = NSEvent.modifierFlags.rawValue
        levelLock.lock()
        let layers = layerStates
        let aliases = layerAliases
        let deltaTime = sceneDeltaTime
        let frame = sceneFrame
        levelLock.unlock()
        context?.setObject(globalValues, forKeyedSubscript: "global" as NSString)
        context?.setObject(layers, forKeyedSubscript: "__layers" as NSString)
        context?.setObject(aliases, forKeyedSubscript: "__layerAliases" as NSString)
        let fps = 1.0 / max(deltaTime, 0.0001)
        context?.evaluateScript("var thisScene = { time: \(time), currentTime: \(time), dt: \(deltaTime), fps: \(fps), getLayer: function(layer) { var key = String(layer); return __layers[__layerAliases[key] || key]; } };")
        let layer = layerId.flatMap { layers[$0] } ?? ["value": input]
        context?.setObject(layer, forKeyedSubscript: "thisLayer" as NSString)
        context?.setObject(["time": time, "frametime": deltaTime, "dt": deltaTime, "frame": frame], forKeyedSubscript: "engine" as NSString)
        context?.setObject(["cursor": cursor, "mouse": cursor, "buttons": mouseButtons, "modifiers": modifiers,
                    "leftDown": (mouseButtons & 1) != 0, "rightDown": (mouseButtons & 2) != 0],
                   forKeyedSubscript: "input" as NSString)

        let value: JSValue?
        scriptLock.lock()
        let needsInitialization = !initializedScripts.contains(contextKey)
        if needsInitialization { initializedScripts.insert(contextKey) }
        scriptLock.unlock()
        let moduleSource = Self.stripESModuleExports(script)
        let result = needsInitialization ? context?.evaluateScript(moduleSource) : nil
        if needsInitialization, context?.objectForKeyedSubscript("init")?.isObject == true {
            _ = context?.objectForKeyedSubscript("init")?.call(withArguments: [input])
        }
        if context?.objectForKeyedSubscript("update")?.isObject == true {
            value = context?.objectForKeyedSubscript("update")?.call(withArguments: [input])
        } else if script.contains("return") {
            let function: JSValue?
            scriptLock.lock()
            function = returnFunctions[contextKey]
            scriptLock.unlock()
            if let function {
                value = function.call(withArguments: [input])
            } else {
                let compiled = context?.evaluateScript("(function(value) { \(moduleSource) })")
                if let compiled {
                    scriptLock.lock()
                    returnFunctions[contextKey] = compiled
                    scriptLock.unlock()
                }
                value = compiled?.call(withArguments: [input])
            }
        } else {
            value = result
        }
        if let dictionary = context?.objectForKeyedSubscript("__layers")?.toDictionary() as? [String: Any] {
            let updatedLayers = dictionary.compactMapValues { $0 as? [String: Any] }
            levelLock.lock()
            layerStates = updatedLayers
            levelLock.unlock()
        }
        return value
    }

    var audioLevel: Double {
        levelLock.lock()
        defer { levelLock.unlock() }
        return level
    }

    private var audioSpectrum: [Double] {
        levelLock.lock()
        defer { levelLock.unlock() }
        return spectrum
    }

    private func startSystemAudioCapture() {
        guard hasScreenCaptureAccess() else { return }
        Task { [weak self] in
            guard let self, let display = try? await SCShareableContent.current.displays.first else { return }
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = false
            configuration.sampleRate = 48_000
            configuration.channelCount = 2
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try? stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
            try? await stream.startCapture()
            self.stream = stream
        }
    }

    private func hasScreenCaptureAccess() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }

        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.screenCapturePromptedKey) else { return false }
        defaults.set(true, forKey: Self.screenCapturePromptedKey)
        return CGRequestScreenCaptureAccess()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of outputType: SCStreamOutputType) {
        guard outputType == .audio, let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length, dataPointerOut: &dataPointer) == noErr,
              let dataPointer, length >= MemoryLayout<Float>.size else { return }
        let sampleCount = length / MemoryLayout<Float>.size
        let samples = dataPointer.withMemoryRebound(to: Float.self, capacity: sampleCount) { $0 }
        var squaredSum: Float = 0
        vDSP_svesq(samples, 1, &squaredSum, vDSP_Length(sampleCount))
        let normalizedLevel = min(Double(sqrt(squaredSum / Float(sampleCount))) * 8, 1)
        let magnitudes = frequencyMagnitudes(samples: samples, count: sampleCount)
        levelLock.lock()
        level = normalizedLevel
        spectrum = magnitudes
        levelLock.unlock()
    }

    private func frequencyMagnitudes(samples: UnsafePointer<Float>, count: Int) -> [Double] {
        let fftSize = min(1024, count)
        guard fftSize >= 64 else { return [Double](repeating: 0, count: 64) }
        let start = count - fftSize
        var bands = [Double](repeating: 0, count: 64)
        for band in 0..<bands.count {
            let bin = max(1, min(fftSize / 2 - 1, (band + 1) * fftSize / 128))
            var real: Double = 0
            var imaginary: Double = 0
            for sampleIndex in 0..<fftSize {
                let window = 0.5 - 0.5 * cos(2 * .pi * Double(sampleIndex) / Double(fftSize - 1))
                let phase = 2 * .pi * Double(bin * sampleIndex) / Double(fftSize)
                let sample = Double(samples[start + sampleIndex]) * window
                real += sample * cos(phase)
                imaginary -= sample * sin(phase)
            }
            bands[band] = min(sqrt(real * real + imaginary * imaginary) * 16 / Double(fftSize), 1)
        }
        return bands
    }
}