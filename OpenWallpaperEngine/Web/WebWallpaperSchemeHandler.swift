//
//  WebWallpaperSchemeHandler.swift
//  Open Wallpaper Engine
//
//  Serves a web wallpaper's folder under `owe-wallpaper://local/…` so its files can be patched in
//  memory (`WebCompatPatches`) on the way to the page. Only wallpapers with patches use it; the
//  rest load straight from file URLs.
//

import Foundation
import UniformTypeIdentifiers
import WebKit

final class WebWallpaperSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "owe-wallpaper"
    static let host = "local"

    /// Read on the main thread only (WebKit calls the handler there); the view model swaps it
    /// when the wallpaper changes.
    var directory: URL?
    var patches = WebCompatPatches(actions: [])

    static func url(forRelativePath path: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/" + WebCompatPatches.normalize(path)
        return components.url
    }

    /// The file a request names, confined to the wallpaper folder.
    static func fileURL(for requestURL: URL, in directory: URL) -> (url: URL, relativePath: String)? {
        let relative = WebCompatPatches.normalize(requestURL.path(percentEncoded: false))
        guard !relative.isEmpty else { return nil }
        let root = directory.standardizedFileURL
        let file = root.appending(path: relative).standardizedFileURL
        guard file.path.hasPrefix(root.path + "/") else { return nil }
        return (file, relative)
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url, let directory,
              let target = Self.fileURL(for: requestURL, in: directory) else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let data: Data
        do {
            data = patches.apply(to: try Data(contentsOf: target.url), relativePath: target.relativePath)
        } catch {
            // Pages probe for optional files; a miss is reported to the page as a 404.
            OWELog.debug(.web, "Web wallpaper file \(target.relativePath) unavailable: \(error)")
            let response = HTTPURLResponse(url: requestURL, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didFinish()
            return
        }
        let mime = UTType(filenameExtension: target.url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let response = HTTPURLResponse(url: requestURL, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": mime,
                                                      "Content-Length": String(data.count),
                                                      "Access-Control-Allow-Origin": "*"])!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
