//
//  WebWallpaperViewModel.swift
//  Open Wallpaper Engine
//
//  Created by Toby on 2023/8/28.
//

import WebKit
import SwiftUI

class WebWallpaperViewModel: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var currentWallpaper: WEWallpaper
    
    var fileUrl: URL {
        currentWallpaper.wallpaperDirectory.appending(path: currentWallpaper.project.file)
    }
    
    var readAccessURL: URL {
        currentWallpaper.wallpaperDirectory
    }
    
    weak var webView: WKWebView?
    /// Serves wallpapers that WE patches (`assets/zcompat/web`) with the patches applied.
    let schemeHandler = WebWallpaperSchemeHandler()

    /// WE's compatibility patches for the current wallpaper, if it has any.
    var compatPatches: WebCompatPatches? {
        let id = SceneWallpaperViewModel.workshopId(of: currentWallpaper)
        return WebCompatPatches(workshopId: id, assetsDirectory: WallpaperEngineAssets.directory)
            ?? WebCompatPatches(workshopId: id, assetsDirectory: WallpaperEngineAssets.bundled)
    }
    /// Receives the page's frame intervals and heartbeats (a page that stops beating is hung).
    weak var renderWatchdog: RenderWatchdog?
    private var heartbeatGate = WebHeartbeatGate()
    /// Whether the current page has beaten yet: one that never runs the bridge (a load error
    /// page) is not judged.
    private var pageHasBeaten = false
    private var visibilityObservers: [NSObjectProtocol] = []
    private var audioTimer: Timer?
    private var propertyObserver: NSObjectProtocol?

    init(wallpaper: WEWallpaper) {
        self.currentWallpaper = wallpaper
        super.init()
        propertyObserver = NotificationCenter.default.addObserver(
            forName: .wallpaperUserPropertyChanged, object: nil, queue: .main
        ) { [weak self] notification in
            self?.propertyChanged(notification)
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemWillSleep(_:)), name: NSWorkspace.screensDidSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemDidWake(_:)), name: NSWorkspace.didWakeNotification, object: nil)
        observeVisibility()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let propertyObserver { NotificationCenter.default.removeObserver(propertyObserver) }
        for observer in visibilityObservers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        audioTimer?.invalidate()
        renderWatchdog?.endHeartbeat(from: ObjectIdentifier(self))
    }

    // MARK: Heartbeat

    /// Tracks what makes WebKit stop the page's timers: an occluded window and sleeping displays
    /// (system sleep also sleeps the displays).
    private func observeVisibility() {
        let workspace = NSWorkspace.shared.notificationCenter
        let displays: [(Notification.Name, Bool)] = [
            (NSWorkspace.screensDidSleepNotification, false), (NSWorkspace.screensDidWakeNotification, true),
            (NSWorkspace.willSleepNotification, false), (NSWorkspace.didWakeNotification, true),
            (NSWorkspace.sessionDidResignActiveNotification, false), (NSWorkspace.sessionDidBecomeActiveNotification, true),
        ]
        for (name, awake) in displays {
            visibilityObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.heartbeatGate.displaysAwake = awake
                self?.reportHeartbeatGate()
            })
        }
        visibilityObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, let window = notification.object as? NSWindow, window === self.webView?.window else { return }
            self.heartbeatGate.windowVisible = window.occlusionState.contains(.visible)
            self.reportHeartbeatGate()
        })
    }

    /// A new page is loading; it is judged from its first heartbeat on.
    func pageWillLoad() {
        pageHasBeaten = false
        renderWatchdog?.recordHeartbeat(from: ObjectIdentifier(self), expectingMore: false)
    }

    /// Restarts the heartbeat clock when the gate opens and stops it when it closes.
    private func reportHeartbeatGate() {
        guard pageHasBeaten else { return }
        renderWatchdog?.recordHeartbeat(from: ObjectIdentifier(self), expectingMore: heartbeatGate.expectsHeartbeats)
    }

    fileprivate func heartbeatReceived(_ heartbeat: WebWallpaperPropertyBridge.Heartbeat) {
        heartbeat.intervals.forEach { renderWatchdog?.recordFrame(duration: $0) }
        heartbeatGate.pageVisible = heartbeat.visible
        pageHasBeaten = true
        reportHeartbeatGate()
    }

    // MARK: Wallpaper Engine web API

    func installBridge(on controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: WebWallpaperPropertyBridge.bootstrapScript,
                                              injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.add(WeakScriptMessageHandler(self), name: WebWallpaperPropertyBridge.audioMessageName)
        controller.add(WeakScriptMessageHandler(self), name: WebWallpaperPropertyBridge.frameMessageName)
    }

    private var declaredProperties: [String: WebWallpaperPropertyBridge.Property] {
        WebWallpaperPropertyBridge.declaredProperties(wallpaperDirectory: currentWallpaper.wallpaperDirectory)
    }

    /// Sends every declared property, as WE does once the page has loaded.
    private func applyAllProperties(to webView: WKWebView) {
        let properties = declaredProperties
        let stored = UserDefaults.standard.dictionary(
            forKey: WallpaperSettingsIdentity.resolve(currentWallpaper).key(.userProperties)) as? [String: String] ?? [:]
        let values = WebWallpaperPropertyBridge.currentValues(properties: properties, stored: stored)
        if let script = WebWallpaperPropertyBridge.applyUserPropertiesScript(
            WebWallpaperPropertyBridge.payload(properties: properties, values: values)) {
            webView.evaluateJavaScript(script, completionHandler: nil)
        }
        webView.evaluateJavaScript(WebWallpaperPropertyBridge.applyGeneralPropertiesScript(fps: 30), completionHandler: nil)
    }

    private func propertyChanged(_ notification: Notification) {
        guard let path = notification.object as? String, path == currentWallpaper.wallpaperDirectory.path,
              let key = notification.userInfo?["key"] as? String,
              let value = notification.userInfo?["value"] as? String,
              let webView else { return }
        let payload = WebWallpaperPropertyBridge.payload(properties: declaredProperties, values: [key: value])
        if let script = WebWallpaperPropertyBridge.applyUserPropertiesScript(payload) {
            webView.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    fileprivate func audioListenerRegistered() {
        guard audioTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self, let webView = self.webView else { return }
            let snapshot = WallpaperServices.shared.audioSpectrumSnapshot
            let samples = WebWallpaperPropertyBridge.audioArray(left: snapshot.left64, right: snapshot.right64)
            webView.evaluateJavaScript(WebWallpaperPropertyBridge.audioDeliveryScript(samples), completionHandler: nil)
        }
        RunLoop.main.add(timer, forMode: .common)
        audioTimer = timer
    }

    func stopAudio() {
        audioTimer?.invalidate()
        audioTimer = nil
    }
    
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Allow navigation to external URLs (e.g. YouTube embeds from URL-based web wallpapers)
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let javascriptStyle = "var css = '*{-webkit-touch-callout:none;-webkit-user-select:none}'; var head = document.head || document.getElementsByTagName('head')[0]; var style = document.createElement('style'); style.type = 'text/css'; style.appendChild(document.createTextNode(css)); head.appendChild(style);"
        webView.evaluateJavaScript(javascriptStyle, completionHandler: nil)
        applyAllProperties(to: webView)
        
        if AppDelegate.shared.globalSettingsViewModel.settings.adjustMenuBarTint {
            webView.takeSnapshot(with: nil) { [weak self] nsImage, error in
                guard let self = self else { return }
                if let data = nsImage?.tiffRepresentation {
                    do {
                        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "staticWP_\(self.currentWallpaper.wallpaperDirectory.hashValue).tiff")
                        try data.write(to: url, options: .atomic)
                        try NSWorkspace.shared.setDesktopImageURL(url, for: .main!)
                    } catch {
                        OWELog.error(.web, "Menu bar tint snapshot failed: \(error)")
                    }
                }
            }
        }
    }
    
    @objc func systemWillSleep(_ notification: Notification) {
        // Handle going to sleep
        OWELog.info(.web, "System is going to sleep")
        // Update your SwiftUI state here if needed
    }
        
    @objc func systemDidWake(_ notification: Notification) {
        // Handle waking up
        OWELog.info(.web, "System woke up from sleep")
        // Update your SwiftUI state here if needed
    }
}

/// Breaks the WKUserContentController → handler retain cycle.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var owner: WebWallpaperViewModel?

    init(_ owner: WebWallpaperViewModel) {
        self.owner = owner
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.name {
        case WebWallpaperPropertyBridge.audioMessageName:
            owner?.audioListenerRegistered()
        case WebWallpaperPropertyBridge.frameMessageName:
            guard let heartbeat = WebWallpaperPropertyBridge.heartbeat(from: message.body) else {
                OWELog.debug(.web, "Ignoring a malformed heartbeat message")
                return
            }
            owner?.heartbeatReceived(heartbeat)
        default:
            break
        }
    }
}
