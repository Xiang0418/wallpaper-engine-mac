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
    
    init(_ gifName: String, animates: Bool = true) {
        self.gifName = gifName
        self.animates = animates
    }
    
    init(contentsOf url: URL, animates: Bool = true) {
        self.gifUrl = url
        self.animates = animates
    }
    
    final class Coordinator {
        var source: URL?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.canDrawSubviewsIntoLayer = true
        view.imageScaling = .scaleProportionallyUpOrDown
        return view
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        let source = gifUrl ?? gifName.flatMap { Bundle.main.url(forResource: $0, withExtension: "gif") }
        if context.coordinator.source != source {
            context.coordinator.source = source
            nsView.image = source.flatMap { NSImage(contentsOf: $0) }
            (nsView.image?.representations.first as? NSBitmapImageRep)?.setProperty(.loopCount, withValue: 0)
        }
        nsView.animates = animates
        updateModifiers(nsView)
    }

    static func dismantleNSView(_ nsView: NSImageView, coordinator: Coordinator) {
        nsView.animates = false
        nsView.image = nil
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSImageView, context: Context) -> CGSize? {
        if !self.isResizable {
            return nsView.sizeThatFits(nsView.frame.size)
        } else {
            guard let width = proposal.width, let height = proposal.height else { return nil }
            return CGSize(width: width, height: height)
        }
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
