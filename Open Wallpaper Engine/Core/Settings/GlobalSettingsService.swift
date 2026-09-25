//
//  GlobalSettingsService.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/9/2.
//

import Cocoa
import Combine
import SwiftUI
import ServiceManagement

@MainActor
class GlobalSettingsViewModel: ObservableObject {
    private static let wallpaperEngineAssetsDirectoryKey = "WallpaperEngineAssetsDirectory"

    @Published var settings: GlobalSettings
    {
        didSet {
            save()
            validate()
            OWELog.apply(logLevel: settings.logLevel)
        }
    }
    
    @Published var selection = 0
    
    @Published var isFirstLaunch = UserDefaults.standard.value(forKey: "IsFirstLaunch") as? Bool ?? true
    
    var didFinishLaunchingNotificationCancellable: Cancellable?
    var didActivateApplicationNotificationCancellable: Cancellable?
    var didCurrentWallpaperChangeCancellable: Cancellable?
    var didAddToLoginItemCancellable: Cancellable?
    var didChangeAdjustMenuBarTintCancellable: Cancellable?
    
    init() {
        if let data = UserDefaults.standard.data(forKey: "GlobalSettings"),
           let settings = try? JSONDecoder().decode(GlobalSettings.self, from: data) {
            self.settings = settings
        } else {
            self.settings = GlobalSettings()
        }
        UserDefaults.standard.set(settings.wallpaperEngineAssetsDirectory,
                                  forKey: Self.wallpaperEngineAssetsDirectoryKey)
        OWELog.apply(logLevel: settings.logLevel)

        // Add observers
        self.didFinishLaunchingNotificationCancellable =
        NotificationCenter.default.publisher(for: NSApplication.didFinishLaunchingNotification)
            .sink { [weak self] _ in self?.didFinishLaunchingNotification() }
    }
    
    deinit {
        didActivateApplicationNotificationCancellable?.cancel()
        didFinishLaunchingNotificationCancellable?.cancel()
        didCurrentWallpaperChangeCancellable?.cancel()
        didAddToLoginItemCancellable?.cancel()
        didChangeAdjustMenuBarTintCancellable?.cancel()
    }
    
    func didFinishLaunchingNotification() {
        self.didActivateApplicationNotificationCancellable =
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] _ in self?.activateApplicationDidChange() }
        
        self.didCurrentWallpaperChangeCancellable =
        AppDelegate.shared.wallpaperViewModel.$wallpapers
            .sink { [weak self] wallpapers in
                let mainId = WallpaperViewModel.mainScreenId()
                if let wp = wallpapers[mainId] {
                    self?.didCurrentWallpaperChange(wp)
                }
            }
        
        self.didAddToLoginItemCancellable =
        self.$settings
            .removeDuplicates { $0.autoStart == $1.autoStart }
            .map { $0.autoStart }
            .sink { [weak self] in self?.didAddToLoginItem($0) }
        
        self.didChangeAdjustMenuBarTintCancellable =
        self.$settings
            .removeDuplicates { $0.adjustMenuBarTint == $1.adjustMenuBarTint }
            .map { $0.adjustMenuBarTint }
            .sink { [weak self] in self?.didChangeAdjustMenuBarTint($0) }
            
        
        self.validate()
    }
    
    func didAddToLoginItem(_ added: Bool) {
        let appService = SMAppService.mainApp
        do {
            if added {
                try appService.register()
            } else {
                try appService.unregister()
            }
        } catch {
            print(error)
        }
    }
    
    func didChangeAdjustMenuBarTint(_ newValue: Bool) {
        if newValue != true {
            if let wallpaper = UserDefaults.standard.url(forKey: "OSWallpaper") {
                try? NSWorkspace.shared.setDesktopImageURL(wallpaper, for: .main!)
            }
        } else {
            do {
                let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "staticWP_\(AppDelegate.shared.wallpaperViewModel.currentWallpaper.wallpaperDirectory.hashValue).tiff")
                try NSWorkspace.shared.setDesktopImageURL(url, for: .main!)
            } catch {
                print(error)
            }
        }
    }
    
    func didCurrentWallpaperChange(_ newValue: WEWallpaper) {
        AppDelegate.shared.setPlacehoderWallpaper(with: newValue)
    }
    
    func reset() {
        settings = (try? JSONDecoder()
            .decode(GlobalSettings.self,
                from: UserDefaults.standard.data(forKey: "GlobalSettings")
            ?? Data()))
        ?? GlobalSettings()
    }
    
    func save() {
        let data = try! JSONEncoder().encode(settings)
        print(String(describing: String(data: data, encoding: .utf8)))
        UserDefaults.standard.set(data, forKey: "GlobalSettings")
    }

    func setWallpaperEngineAssetsDirectory(_ directory: URL?) {
        settings.wallpaperEngineAssetsDirectory = directory?.standardizedFileURL.path
        UserDefaults.standard.set(settings.wallpaperEngineAssetsDirectory,
                                  forKey: Self.wallpaperEngineAssetsDirectoryKey)
        SceneDynamicEffectCatalog.invalidateSharedCache()
        NotificationCenter.default.post(name: .wallpaperEngineAssetsDirectoryDidChange, object: nil)
    }
    
    func setQuality(_ quality: GSQuality) {
        switch quality {
        case .low:
            self.settings.antiAliasing = .none
            self.settings.postProcessing = .disabled
            self.settings.textureResolution = .highQuality
            self.settings.fps = 10
            self.settings.reflections = false
        case .medium:
            self.settings.antiAliasing = .none
            self.settings.postProcessing = .enabled
            self.settings.textureResolution = .highQuality
            self.settings.fps = 15
            self.settings.reflections = true
        case .high:
            self.settings.antiAliasing = .msaa_x2
            self.settings.postProcessing = .enabled
            self.settings.textureResolution = .highQuality
            self.settings.fps = 25
            self.settings.reflections = true
        case .ultra:
            self.settings.antiAliasing = .msaa_x2
            self.settings.postProcessing = .ultra
            self.settings.textureResolution = .highQuality
            self.settings.fps = 30
            self.settings.reflections = true
        }
    }
    
    private func validate() {
        switch settings.appearance {
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        case .followSystem:
            NSApp.appearance = nil
        }
    }
    
    func activateApplicationDidChange() {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else { return }

        switch frontmostApplication.bundleIdentifier {
        case "com.apple.finder", Bundle.main.bundleIdentifier:
            globalSettingsWhenApplicationDidBecomeActive()
        default:
            switch self.settings.otherApplicationFocused {
            case .mute:
                AppDelegate.shared.mute()
            case .pause:
                AppDelegate.shared.pause()
            case .stop:
                AppDelegate.shared.pause()
                for window in AppDelegate.shared.wallpaperWindows.values { window.orderOut(nil) }
            case .keepRunning:
                break
            }
        }
    }

    func globalSettingsWhenApplicationDidBecomeActive() {
        switch self.settings.otherApplicationFocused {
        case .mute:
            AppDelegate.shared.unmute()
        case .pause:
            AppDelegate.shared.resume()
        case .stop:
            AppDelegate.shared.resume()
            for window in AppDelegate.shared.wallpaperWindows.values { window.orderFront(nil) }
        case .keepRunning:
            break
        }
    }
    
    private func saveAndValidate() {
        save()
        validate()
    }
}
