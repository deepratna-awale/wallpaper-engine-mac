//
//  GifImage.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/15.
//

import Cocoa
import SwiftUI

struct GifImage: NSViewRepresentable {
    
    var gifName: String?
    var gifUrl: URL?
    
    var isResizable: Bool = false
    var contentMode: ContentMode = .fill
    
    var animates: Bool

    final class Coordinator {
        var loadedSource: String?
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
        guard let url, let image = NSImage(contentsOf: url) else { return }
        (image.representations.first as? NSBitmapImageRep)?.setProperty(.loopCount, withValue: 0)
        nsView.image = image
        coordinator.loadedSource = source
    }

    private func updateModifiers(_ nsView: NSImageView) {
        if self.isResizable {
            switch self.contentMode {
            case .fill:
                nsView.imageScaling = .scaleAxesIndependently
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
