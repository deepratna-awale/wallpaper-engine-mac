import Cocoa
import Combine
import SwiftUI
import ServiceManagement

extension Notification.Name {
    static let wallpaperEngineAssetsDirectoryDidChange = Notification.Name("WallpaperEngineAssetsDirectoryDidChange")
}

enum GSQuality {
    case low, medium, high, ultra
}

enum GSPlayback: String, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    case keepRunning, mute, pause, stop
}

enum GSAntiAliasingQuality: String, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    case none, msaa_x2, msaa_x4, msaa_x8
}

/// WE's `postprocessing` setting (docs/lighting-plan.md §2.6): "disabled" turns bloom off,
/// "ultra" lets a scene with `bloom` and `hdr` draw in HDR, "displayhdr" also outputs HDR.
enum GSPostProcessingQuality: String, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    case disabled, enabled, ultra, displayhdr
}

/// WE's `shadows` and `volumetrics` settings: disabled, low, medium, high, ultra.
enum GSLightingQuality: String, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    case disabled, low, medium, high, ultra

    /// WE's number for the setting, 0 (disabled) … 4 (ultra).
    var level: Int {
        switch self {
        case .disabled: return 0
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        case .ultra: return 4
        }
    }
}

enum GSTextureResolutionQuality: String, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    case highQuality, highPerformance, automatic
}

enum GSAppearance: String, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    case light, dark, followSystem
}

enum GSLocalization: String, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    case en_US, zh_CN, followSystem
}

enum GSVideoFramework: String, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    case avkit
    /// Draws video through the scene renderer so the effect stack applies to it, the way
    /// Wallpaper Engine does. Still experimental; avkit remains the default.
    case metal
}

enum GSProcessPiority: String, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    case normal, belowNormal
}

enum GSLogLevel: String, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    case error, verbose, none
}

struct GlobalSettings: Codable, Equatable {
    
    // MARK: Playback
    var otherApplicationFocused = GSPlayback.keepRunning
    var otherApplicationFullscreen = GSPlayback.keepRunning
    var otherApplicationPlayingAudio = GSPlayback.keepRunning
    var displayAsleep = GSPlayback.keepRunning
    var laptopOnBattery = GSPlayback.keepRunning
    
    // MARK: Quality
    var antiAliasing = GSAntiAliasingQuality.msaa_x2
    /// "enabled" draws WE's bloom as the app always has. WE's own UI default is unknown (its
    /// engine reads a missing key as "disabled"; docs/lighting-plan.md §5).
    var postProcessing = GSPostProcessingQuality.enabled
    var textureResolution = GSTextureResolutionQuality.automatic
    /// WE's `reflection` setting (default on): the screen-space reflection copy.
    var reflections = true
    /// WE's `shadows` setting; medium is WE's default.
    var shadows = GSLightingQuality.medium
    /// WE's `volumetrics` setting, on the same scale as `shadows` [?: default taken as shadows'].
    var volumetrics = GSLightingQuality.medium
    var fps: Double = 30
    
    // MARK: Automatic Setup
    var autoStart = false
    var safeMode = false
    
    // MARK: Basic Setup
    var language = GSLocalization.followSystem
    
    // MARK: macOS
    var adjustMenuBarTint = true
    
    // MARK: Appearance
    var appearance = GSAppearance.followSystem
    
    // MARK: Audio
    var audioOutput = true
    var reloadWhenChangingOutputDevice = true // Not putting in use
    
    // MARK: Video
    var videoFramework = GSVideoFramework.avkit
    
    // MARK: Advanced
    var processPiority = GSProcessPiority.normal // Not putting in use
    var pauseOnVRAMExhausted = false // Not putting in use
    var restartAfterCrashing = false // Not putting in use
    
    // MARK: Developer
    var logLevel = GSLogLevel.none
    
    // MARK: Misc
    var autoRefresh = true

    // MARK: Scene Assets
    var wallpaperEngineAssetsDirectory: String?

    /// The stored keys. `postProcessing` and `reflections` moved to new keys when the renderer
    /// started reading them: the old keys hold values saved while the settings did nothing
    /// (post-processing then defaulted to "disabled"), so they are left behind.
    enum CodingKeys: String, CodingKey {
        case otherApplicationFocused, otherApplicationFullscreen, otherApplicationPlayingAudio, displayAsleep
        case laptopOnBattery, antiAliasing, textureResolution, shadows, volumetrics, fps
        case postProcessing = "postProcessingQuality"
        case reflections = "reflection"
        case autoStart, safeMode, language, adjustMenuBarTint, appearance, audioOutput
        case reloadWhenChangingOutputDevice, videoFramework, processPiority, pauseOnVRAMExhausted
        case restartAfterCrashing, logLevel, autoRefresh, wallpaperEngineAssetsDirectory
    }
}

extension GlobalSettings {
    /// Reads each stored setting on its own: a key that is missing (a setting added since the
    /// settings were saved) or unreadable keeps its default, and the others are kept.
    init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func read<Value: Decodable>(_ key: CodingKeys, _ value: inout Value) {
            do {
                if let stored = try container.decodeIfPresent(Value.self, forKey: key) { value = stored }
            } catch {
                OWELog.error(.settings, "Setting \(key.stringValue) can't be read and keeps its default: \(error)")
            }
        }
        read(.otherApplicationFocused, &otherApplicationFocused)
        read(.otherApplicationFullscreen, &otherApplicationFullscreen)
        read(.otherApplicationPlayingAudio, &otherApplicationPlayingAudio)
        read(.displayAsleep, &displayAsleep)
        read(.laptopOnBattery, &laptopOnBattery)
        read(.antiAliasing, &antiAliasing)
        read(.postProcessing, &postProcessing)
        read(.textureResolution, &textureResolution)
        read(.reflections, &reflections)
        read(.shadows, &shadows)
        read(.volumetrics, &volumetrics)
        read(.fps, &fps)
        read(.autoStart, &autoStart)
        read(.safeMode, &safeMode)
        read(.language, &language)
        read(.adjustMenuBarTint, &adjustMenuBarTint)
        read(.appearance, &appearance)
        read(.audioOutput, &audioOutput)
        read(.reloadWhenChangingOutputDevice, &reloadWhenChangingOutputDevice)
        read(.videoFramework, &videoFramework)
        read(.processPiority, &processPiority)
        read(.pauseOnVRAMExhausted, &pauseOnVRAMExhausted)
        read(.restartAfterCrashing, &restartAfterCrashing)
        read(.logLevel, &logLevel)
        read(.autoRefresh, &autoRefresh)
        read(.wallpaperEngineAssetsDirectory, &wallpaperEngineAssetsDirectory)
    }
}
