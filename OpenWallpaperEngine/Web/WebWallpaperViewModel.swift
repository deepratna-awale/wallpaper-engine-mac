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
    /// Receives the page's frame intervals (the render watchdog's frame times).
    var frameTimeObserver: ((TimeInterval) -> Void)?
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
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let propertyObserver { NotificationCenter.default.removeObserver(propertyObserver) }
        audioTimer?.invalidate()
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
            forKey: WebWallpaperPropertyBridge.storageKey(for: currentWallpaper.wallpaperDirectory)) as? [String: String] ?? [:]
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
            let snapshot = AudioReactiveScriptEngine.shared.audioSpectrumSnapshot
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
            guard let observer = owner?.frameTimeObserver else { return }
            WebWallpaperPropertyBridge.frameIntervals(from: message.body).forEach(observer)
        default:
            break
        }
    }
}
