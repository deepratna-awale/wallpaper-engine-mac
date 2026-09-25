//
//  GifImage.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/15.
//

import Cocoa
import SwiftUI
import ImageIO

struct GifImage: NSViewRepresentable {
    private static let imageCache = NSCache<NSString, NSImage>()
    
    var gifName: String?
    var gifUrl: URL?
    
    var isResizable: Bool = false
    var contentMode: ContentMode = .fill
    
    var animates: Bool

    final class Coordinator {
        var loadedSource: String?
        var loadingSource: String?
    }
    
    init(_ gifName: String, animates: Bool = true) {
        self.gifName = gifName
        self.animates = animates
    }
    
    init(contentsOf url: URL, animates: Bool = true) {
        self.gifUrl = url
        self.animates = animates
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    func makeNSView(context: Context) -> NSImageView {
        let nsView = NSImageView()
        
        nsView.canDrawSubviewsIntoLayer = true
        nsView.imageScaling = .scaleProportionallyUpOrDown
        nsView.animates = animates
        
        loadImage(into: nsView, coordinator: context.coordinator)
        
        return nsView
    }
    
    func updateNSView(_ nsView: NSImageView, context: Context) {
        nsView.animates = animates
        loadImage(into: nsView, coordinator: context.coordinator)
        updateModifiers(nsView)
    }
    
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSImageView, context: Context) -> CGSize? {
        if !self.isResizable {
            return nsView.sizeThatFits(nsView.frame.size)
        } else {
            guard let width = proposal.width, let height = proposal.height else { return nil }
            return CGSize(width: width, height: height)
        }
    }
    
    private func loadImage(into nsView: NSImageView, coordinator: Coordinator) {
        let source = gifUrl?.path ?? gifName
        guard coordinator.loadedSource != source else { return }
        let url = gifUrl ?? gifName.flatMap { Bundle.main.url(forResource: $0, withExtension: "gif") }
        guard let url, let source else { return }
        if let cached = Self.imageCache.object(forKey: source as NSString) {
            nsView.image = cached
            coordinator.loadedSource = source
            return
        }
        guard coordinator.loadingSource != source else { return }
        coordinator.loadingSource = source
        let shouldAnimate = animates
        DispatchQueue.global(qos: .userInitiated).async {
            let image: NSImage?
            if shouldAnimate {
                image = NSImage(contentsOf: url)
            } else {
                image = Self.downsampledImage(at: url, maxPixelSize: 512)
            }
            guard let image else { return }
            let prepared = self.contentMode == .fill ? self.centeredSquareCrop(image) : image
            Self.imageCache.setObject(prepared, forKey: source as NSString)
            DispatchQueue.main.async {
                guard coordinator.loadingSource == source else { return }
                nsView.image = prepared
                coordinator.loadedSource = source
                coordinator.loadingSource = nil
            }
        }
    }

    private static func downsampledImage(at url: URL, maxPixelSize: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    private func centeredSquareCrop(_ image: NSImage) -> NSImage {
        let width = image.size.width
        let height = image.size.height
        guard width > height, height > 0 else { return image }
        let cropRect = NSRect(x: (width - height) / 2, y: 0, width: height, height: height)
        let cropped = NSImage(size: NSSize(width: height, height: height))
        cropped.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: cropped.size),
                   from: cropRect, operation: .copy, fraction: 1)
        cropped.unlockFocus()
        return cropped
    }

    private func updateModifiers(_ nsView: NSImageView) {
        if self.isResizable {
            switch self.contentMode {
            case .fill:
                // Keep the source aspect ratio; the containing view handles the crop.
                nsView.imageScaling = .scaleProportionallyUpOrDown
            case .fit:
                nsView.imageScaling = .scaleProportionallyUpOrDown
            }
        }
    }
    
    func resizable(capInsets: EdgeInsets = EdgeInsets(), resizingMode: Image.ResizingMode = .stretch) -> Self {
        var view = self
        view.isResizable = true
        return view
    }
    
    func aspectRatio(_ aspectRatio: CGFloat? = nil, contentMode: ContentMode) -> Self {
        var view = self
        view.contentMode = contentMode
        return view
    }
}
