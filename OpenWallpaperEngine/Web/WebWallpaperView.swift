//
//  WebWallpaperView.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/13.
//

import Cocoa
import SwiftUI
import WebKit

struct WebWallpaperView: NSViewRepresentable {
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    @StateObject var viewModel: WebWallpaperViewModel
    let screenId: String

    init(wallpaperViewModel: WallpaperViewModel, screenId: String) {
        self.wallpaperViewModel = wallpaperViewModel
        self.screenId = screenId
        self._viewModel = StateObject(wrappedValue: WebWallpaperViewModel(wallpaper: wallpaperViewModel.wallpaper(for: screenId)))
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        Self.enableFileAccess(on: configuration)
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        viewModel.installBridge(on: configuration.userContentController)

        let nsView = WKWebView(frame: .zero, configuration: configuration)
        nsView.navigationDelegate = viewModel
        viewModel.webView = nsView
        Self.loadWallpaper(nsView, viewModel: viewModel)
        return nsView
    }

    /// Load wallpaper — uses loadHTMLString for URL-based wallpapers (YouTube/Vimeo)
    /// so the origin isn't file://, or loadFileURL for local wallpapers.
    private static func loadWallpaper(_ webView: WKWebView, viewModel: WebWallpaperViewModel) {
        let fileUrl = viewModel.fileUrl
        // Check if the HTML contains a redirect/embed to an external URL
        if let html = try? String(contentsOf: fileUrl, encoding: .utf8),
           html.contains("youtube.com") || html.contains("vimeo.com") {
            // Load as HTML string with https origin so YouTube/Vimeo embeds work
            webView.loadHTMLString(html, baseURL: URL(string: "https://localhost"))
        } else {
            webView.loadFileURL(fileUrl, allowingReadAccessTo: viewModel.readAccessURL)
        }
    }

    /// Enable file:// cross-origin access for WebGL wallpapers.
    /// Tries multiple private WebKit key variants, catching ObjC exceptions for each.
    private static func enableFileAccess(on configuration: WKWebViewConfiguration) {
        let prefs = configuration.preferences

        // Key variants across macOS versions
        let fileAccessKeys = ["allowFileAccessFromFileURLs", "_allowFileAccessFromFileURLs"]
        let universalAccessKeys = ["allowUniversalAccessFromFileURLs", "_allowUniversalAccessFromFileURLs"]

        for key in fileAccessKeys {
            if ObjCExceptionCatcher.performSafe({ prefs.setValue(true, forKey: key) }) { break }
        }

        for key in universalAccessKeys {
            if ObjCExceptionCatcher.performSafe({ prefs.setValue(true, forKey: key) }) { break }
        }
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        let selectedWallpaper = wallpaperViewModel.wallpaper(for: screenId)
        let currentWallpaper = viewModel.currentWallpaper

        if selectedWallpaper.wallpaperDirectory.appending(path: selectedWallpaper.project.file) != currentWallpaper.wallpaperDirectory.appending(path: currentWallpaper.project.file) {
            viewModel.currentWallpaper = selectedWallpaper
            viewModel.stopAudio()
            Self.loadWallpaper(nsView, viewModel: viewModel)
        }
        applyPlacement(wallpaperViewModel.wallpaperPlacement, to: nsView)
    }

    private func applyPlacement(_ placement: WallpaperPlacement, to webView: WKWebView) {
        let objectFit: String
        switch placement {
        case .stretch:
            objectFit = "fill"
        case .fill, .zoom:
            objectFit = "cover"
        case .fit, .center:
            objectFit = "contain"
        }
        let javascript = "document.documentElement.style.width='100%';document.documentElement.style.height='100%';document.body.style.margin='0';document.body.style.width='100%';document.body.style.height='100%';document.querySelectorAll('video,img,canvas').forEach(function(element){element.style.width='100%';element.style.height='100%';element.style.objectFit='\(objectFit)';});"
        webView.evaluateJavaScript(javascript, completionHandler: nil)
    }
}
