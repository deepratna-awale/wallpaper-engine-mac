//
//  AppDelegate.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/6/6.
//

import Cocoa
import Combine
import SwiftUI
import AVKit
import WebKit

private final class WorkshopPreviewWindow: NSWindow {
    var onDismiss: (() -> Void)?

    override func performClose(_ sender: Any?) {
        orderOut(sender)
        onDismiss?()
    }

    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }

    override func resignKey() {
        super.resignKey()
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isKeyWindow else { return }
            self.orderOut(nil)
            self.onDismiss?()
        }
    }
}

private struct WorkshopPreviewContent: View {
    @ObservedObject var wallpaperViewModel: WallpaperViewModel

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            WallpaperView(
                viewModel: wallpaperViewModel,
                screenId: wallpaperViewModel.selectedScreenId
            )
            .id(wallpaperViewModel.currentWallpaper.wallpaperDirectory)

            HStack(spacing: 10) {
                if SceneWallpaperViewModel.isVideoType(wallpaperViewModel.currentWallpaper.project.type) {
                    Button {
                        wallpaperViewModel.playRate = wallpaperViewModel.playRate == 0
                            ? max(wallpaperViewModel.lastPlayRate, 0.1)
                            : 0
                    } label: {
                        Image(systemName: wallpaperViewModel.playRate == 0 ? "play.fill" : "pause.fill")
                    }
                    .buttonStyle(.bordered)
                    .help(wallpaperViewModel.playRate == 0 ? "Play" : "Pause")

                    NumericSliderInput(value: $wallpaperViewModel.playVolume, range: 0...1,
                                       defaultValue: 1, displayScale: 100, suffix: "%",
                                       fractionDigits: 0, sliderWidth: 110, fieldWidth: 36)
                }

                Button("Set Wallpaper") {
                    AppDelegate.shared.applyWorkshopPreview()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    
    var statusItem: NSStatusItem!
    var settingsWindow: NSWindow!
    
    var mainWindowController: MainWindowController!
    
    var wallpaperWindows: [String: NSWindow] = [:]
    private var workshopPreviewWindow: NSWindow?
    private var workshopPreviewViewModel: WallpaperViewModel?
    var sceneInspectorWindow: NSWindow?
    
    var contentViewModel = ContentViewModel()
    var wallpaperViewModel = WallpaperViewModel()
    var globalSettingsViewModel = GlobalSettingsViewModel()
    lazy var safeRestart = SafeRestart()
    /// What every scene's SceneScripts share: WE's prelude, `localStorage`, the one media session and
    /// the desktop's left clicks.
    lazy var sceneScriptServices: SceneScriptServices = {
        if !SceneScriptJIT.isEnabled {
            OWELog.info(.script, "JavaScriptCore runs without its JIT (no \(SceneScriptJIT.entitlement)): scripts run several times slower")
        }
        let clicks = DesktopClickMonitor()
        clicks.start()
        return SceneScriptServices(
            prelude: SceneScriptPrelude.load(),
            storage: SceneScriptStorage(directory: SceneScriptStorage.defaultDirectory),
            media: MacMediaSessionSource(),
            spectrum: { WallpaperServices.shared.audioSpectrumSnapshot },
            clicks: clicks)
    }()
    /// Fetches the Workshop items shown wallpapers borrow assets from.
    lazy var workshopDependencies = WorkshopDependencyService(steamCmd: contentViewModel.steamCmd)
    private var workshopDependencyCancellable: AnyCancellable?
    private var audioOutputCancellable: AnyCancellable?
    
    var importOpenPanel: NSOpenPanel!
    
    var eventHandler: Any?
    
    static var shared = AppDelegate()
    
    func applicationWillFinishLaunching(_ notification: Notification) {

        workshopDependencyCancellable = wallpaperViewModel.$wallpapers.sink { [weak self] wallpapers in
            for wallpaper in wallpapers.values {
                self?.workshopDependencies.ensureDependencies(for: wallpaper)
            }
        }

        wallpaperViewModel.keepWorkshopPreview = { [steamCmd = contentViewModel.steamCmd] in try steamCmd.keepPreview($0) }

        // Settings → Audio Output silences every wallpaper (`WallpaperAudioRouting`).
        audioOutputCancellable = globalSettingsViewModel.$settings.map(\.audioOutput).removeDuplicates()
            .sink { [weak self] enabled in self?.wallpaperViewModel.audioOutputEnabled = enabled }

        // Before the wallpaper windows exist, so a wallpaper behind an unclean exit never loads.
        safeRestart.attach(to: wallpaperViewModel)

        // 创建设置视窗
        setSettingsWindow()
        
        // 创建桌面壁纸视窗
        setWallpaperWindows()

        // 监听显示器连接/断开
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(audioCapturePermissionMissing),
            name: .audioCapturePermissionMissing, object: nil
        )
        
        // 创建化左上角菜单栏
        setMainMenu()
        
        // 创建化右上角常驻菜单栏
        setStatusMenu()
        
        // 创建主视窗
        self.mainWindowController = MainWindowController()
        
        // 将外部输入传递到壁纸窗口
        AppDelegate.shared.setEventHandler()
    }
    
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let dockMenu = self.statusItem.menu?.copy() as! NSMenu?
        dockMenu?.items.removeLast() // Remove `Quit` menu item
        return dockMenu
    }
    
// MARK: - delegate methods
    func applicationDidFinishLaunching(_ notification: Notification) {
        saveCurrentWallpaper()
        AppDelegate.shared.setPlacehoderWallpaper(with: wallpaperViewModel.currentWallpaper)

        // 显示桌面壁纸
        for (_, window) in self.wallpaperWindows {
            window.orderFront(nil)
        }
        
        safeRestart.showPendingNotice()

        if globalSettingsViewModel.isFirstLaunch {
            self.mainWindowController.window.center()
            self.mainWindowController.window.makeKeyAndOrderFront(nil)
        }

        DispatchQueue.global(qos: .utility).async {
            WallpaperPackageConverter.convertInstalledLibrary()
            if UserDefaults.standard.bool(forKey: "ReclaimOriginalPackages") {
                WallpaperPackageConverter.reclaimEligibleSources()
            }
        }
    }
    
    func applicationDidBecomeActive(_ notification: Notification) {
        contentViewModel.isApplicationActive = true
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationDidResignActive(_ notification: Notification) {
        contentViewModel.isApplicationActive = false
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !self.mainWindowController.window.isVisible && !settingsWindow.isVisible {
            self.mainWindowController.window?.makeKeyAndOrderFront(nil)
        }
        
        return true
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        safeRestart.applicationWillTerminate()
        if let wallpaper = UserDefaults.standard.url(forKey: "OSWallpaper") {
            for screen in NSScreen.screens {
                try? NSWorkspace.shared.setDesktopImageURL(wallpaper, for: screen)
            }
        }
        
        let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        do {
            let filesURL = try FileManager.default.contentsOfDirectory(at: cacheDirectory,
                                                                       includingPropertiesForKeys: nil,
                                                                       options: .skipsHiddenFiles)
            for url in filesURL {
                if url.lastPathComponent.contains("staticWP") {
                    try FileManager.default.removeItem(at: url)
                }
            }
        } catch {
            OWELog.error(.app, "Clearing cached desktop snapshots failed: \(error)")
        }
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

// MARK: - misc methods
    @objc func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        self.settingsWindow.center()
        self.settingsWindow.makeKeyAndOrderFront(nil)
    }
    
    @objc func openMainWindow() {
        self.mainWindowController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @MainActor @objc func toggleFilter() {
        self.contentViewModel.isFilterReveal.toggle()
    }

    /// Posted at most once per launch by `AudioCapturePermissionGate`, and never after
    /// "Don't Ask Again".
    @objc func audioCapturePermissionMissing() {
        let alert = NSAlert()
        alert.messageText = "Audio Visualizers Need Permission"
        alert.informativeText = """
        Open Wallpaper Engine needs Screen & System Audio Recording permission to read system audio \
        for audio bars and other audio-reactive wallpapers. Audio capture starts on its own once \
        the permission is granted.
        """
        alert.addButton(withTitle: "Grant Access")
        alert.addButton(withTitle: "Open Permissions Page")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Don't Ask Again")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            PermissionHelper.grantScreenRecordingAccess()
        case .alertSecondButtonReturn:
            globalSettingsViewModel.selection = 3
            openSettingsWindow()
        case .alertThirdButtonReturn:
            break
        default:
            GlobalSettingsViewModel.isAudioPermissionAlertDismissed = true
        }
    }

// MARK: Set Settings Window
    func setSettingsWindow() {
        self.settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        self.settingsWindow.title = "Settings"
        self.settingsWindow.isReleasedWhenClosed = false
        self.settingsWindow.toolbarStyle = .preference
        
        self.settingsWindow.delegate = self
        
        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.delegate = self
        
        toolbar.selectedItemIdentifier = SettingsToolbarIdentifiers.performance
        
        self.settingsWindow.toolbar = toolbar
        self.settingsWindow.contentView = NSHostingView(rootView: SettingsView().environmentObject(self.globalSettingsViewModel))
    }
    
// MARK: Set Wallpaper Windows - One per screen
    func setWallpaperWindows() {
        for screen in NSScreen.screens {
            let screenId = WallpaperViewModel.screenId(for: screen)
            guard wallpaperViewModel.isScreenEnabled(screenId) else { continue }

            let window = WallpaperWindow()
            window.styleMask = [.borderless, .fullSizeContentView]
            window.level = NSWindow.Level(Int(CGWindowLevelForKey(.desktopWindow)))
            window.collectionBehavior = [.stationary, .canJoinAllSpaces]
            window.setFrame(screen.frame, display: true)
            window.isMovable = false
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.backgroundColor = .black
            window.isOpaque = true
            window.canHide = false
            window.canBecomeVisibleWithoutLogin = true
            window.isReleasedWhenClosed = false
            window.ignoresMouseEvents = true
            window.contentView = NSHostingView(rootView:
                WallpaperView(viewModel: self.wallpaperViewModel, screenId: screenId)
            )
            wallpaperWindows[screenId] = window
        }
    }

    /// Rebuild wallpaper windows without changing enabled state.
    func rebuildWallpaperWindows() {
        for (_, window) in wallpaperWindows {
            // `isReleasedWhenClosed` is false, so the hosting view (and the video players inside
            // it) survives a plain close and keeps playing.
            window.contentView = nil
            window.close()
        }
        wallpaperWindows.removeAll()
        setWallpaperWindows()
        for (_, window) in wallpaperWindows { window.orderFront(nil) }
    }

    @MainActor
    func showWorkshopPreview(_ wallpaper: WEWallpaper) {
        if let previewViewModel = workshopPreviewViewModel,
           let window = workshopPreviewWindow {
            previewViewModel.setWallpaper(wallpaper, for: previewViewModel.selectedScreenId)
            previewViewModel.playRate = wallpaperViewModel.playRate
            previewViewModel.playVolume = wallpaperViewModel.playVolume
            window.title = wallpaper.project.title
            window.makeKeyAndOrderFront(nil)
            return
        }

        let previewViewModel = WallpaperViewModel(persistsWallpapers: false)
        previewViewModel.setWallpaper(wallpaper, for: previewViewModel.selectedScreenId)
        previewViewModel.playRate = wallpaperViewModel.playRate
        previewViewModel.playVolume = wallpaperViewModel.playVolume

        let window = WorkshopPreviewWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.onDismiss = { [weak self] in
            // Hiding the window leaves its wallpaper view — and that view's video players — alive,
            // so the preview has to be torn down rather than just paused.
            guard let self else { return }
            self.workshopPreviewViewModel?.playRate = 0
            self.workshopPreviewViewModel?.playVolume = 0
            self.workshopPreviewWindow?.contentView = nil
            self.workshopPreviewWindow = nil
            self.workshopPreviewViewModel = nil
        }
        window.title = wallpaper.project.title
        window.contentView = NSHostingView(rootView: WorkshopPreviewContent(
            wallpaperViewModel: previewViewModel
        ))
        window.center()
        window.makeKeyAndOrderFront(nil)

        workshopPreviewViewModel = previewViewModel
        workshopPreviewWindow = window
    }

    @MainActor
    func applyWorkshopPreview() {
        guard let wallpaper = workshopPreviewViewModel?.currentWallpaper else { return }
        wallpaperViewModel.inspect(wallpaper)
        wallpaperViewModel.applyInspectedWallpaper()
    }

    /// Called when monitors connect/disconnect — auto-enables newly connected screens.
    @objc func screensChanged() {
        let connectedIds = Set(NSScreen.screens.map { WallpaperViewModel.screenId(for: $0) })
        for id in connectedIds where !wallpaperViewModel.enabledScreens.contains(id) {
            wallpaperViewModel.enabledScreens.insert(id)
        }
        rebuildWallpaperWindows()
    }
    
    func windowWillClose(_ notification: Notification) {
        globalSettingsViewModel.reset()
    }
    
    func setEventHandler() {
        // Only monitor event types we actually handle — .any causes main thread starvation
        let relevantEvents: NSEvent.EventTypeMask = [
            .scrollWheel, .mouseMoved, .mouseEntered, .mouseExited,
            .leftMouseUp, .rightMouseUp, .leftMouseDown,
            .leftMouseDragged, .rightMouseDragged
        ]
        self.eventHandler = NSEvent.addGlobalMonitorForEvents(matching: relevantEvents) { [weak self] event in
            guard let self = self,
                  let frontmostApplication = NSWorkspace.shared.frontmostApplication,
                  frontmostApplication.bundleIdentifier == "com.apple.finder" else { return }

            // Find the WKWebView in whichever wallpaper window the event lands on
            let mouseLocation = NSEvent.mouseLocation
            guard let targetWindow = self.wallpaperWindows.values.first(where: { $0.frame.contains(mouseLocation) }),
                  let webview = targetWindow.contentView?.subviews.first?.subviews.first,
                  webview is WKWebView else { return }

            switch event.type {
            case .scrollWheel:
                webview.scrollWheel(with: event)
            case .mouseMoved:
                webview.mouseMoved(with: event)
            case .mouseEntered:
                webview.mouseEntered(with: event)
            case .mouseExited:
                webview.mouseExited(with: event)
            case .leftMouseUp, .rightMouseUp:
                webview.mouseUp(with: event)
            case .leftMouseDown:
                webview.mouseDown(with: event)
            case .leftMouseDragged, .rightMouseDragged:
                webview.mouseDragged(with: event)
            default:
                break
            }
        }
    }
    
    func saveCurrentWallpaper() {
        guard let mainScreen = NSScreen.main else { return }
        var wallpaper: URL {
            var osWallpaper: URL { NSWorkspace.shared.desktopImageURL(for: mainScreen)! }
            if let wallpaper = UserDefaults.standard.url(forKey: "OSWallpaper") {
                if wallpaper != osWallpaper {
                    if !wallpaper.lastPathComponent.contains("staticWP") {
                        return wallpaper
                    }
                }
            }
            return osWallpaper
        }
        UserDefaults.standard.set(wallpaper, forKey: "OSWallpaper")
    }
    
    func setPlacehoderWallpaper(with wallpaper: WEWallpaper) {
        switch wallpaper.project.type {
        case "video":
            let asset = AVAsset(url: wallpaper.wallpaperDirectory.appending(component: wallpaper.project.file))
            let imageGenerator = AVAssetImageGenerator(asset: asset)
            imageGenerator.appliesPreferredTrackTransform = true
            
            let time = CMTimeMake(value: 1, timescale: 1) // 第一帧的时间
            imageGenerator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, cgImage, _, _, error in
                if let error = error {
                    OWELog.error(.app, "Video thumbnail for desktop picture failed: \(error)")
                } else if let cgImage = cgImage {
                    let nsImage = NSImage(cgImage: cgImage, size: .zero)
                    if let data = nsImage.tiffRepresentation {
                        do {
                            let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "staticWP_\(wallpaper.wallpaperDirectory.hashValue).tiff")
                            try data.write(to: url, options: .atomic)
                            for screen in NSScreen.screens {
                                try NSWorkspace.shared.setDesktopImageURL(url, for: screen)
                            }
                        } catch {
                            OWELog.error(.app, "Setting desktop picture failed: \(error)")
                        }
                    }
                }
            }
        default:
            return
        }
    }
}
