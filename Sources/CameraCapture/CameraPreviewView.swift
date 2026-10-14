import AVFoundation
import AppKit
import SwiftUI

/// A live camera preview for SwiftUI. It shows the frames of a `CameraPreviewFeed`; pass the same
/// feed to `CameraRecorder.openPreview(_:meters:)` (or `prepare(preview:events:)`). Several views can show
/// one feed at once (the menu's preview and the camera window).
///
/// The view holds no capture object. SwiftUI can create and remove it at any time, on any state
/// change, without touching a capture session (see CaptureThreads.swift for why that matters).
public struct CameraPreviewView: NSViewRepresentable {
    public let feed: CameraPreviewFeed
    public var videoGravity: AVLayerVideoGravity
    /// Mirror the picture, like a webcam. Off by default: a capture card shows what the camera sees.
    public var mirrored: Bool

    public init(feed: CameraPreviewFeed, videoGravity: AVLayerVideoGravity = .resizeAspect, mirrored: Bool = false) {
        self.feed = feed
        self.videoGravity = videoGravity
        self.mirrored = mirrored
    }

    public func makeNSView(context: Context) -> CameraPreviewNSView {
        let view = CameraPreviewNSView()
        view.show(feed, videoGravity: videoGravity, mirrored: mirrored)
        return view
    }

    public func updateNSView(_ nsView: CameraPreviewNSView, context: Context) {
        nsView.show(feed, videoGravity: videoGravity, mirrored: mirrored)
    }

    public static func dismantleNSView(_ nsView: CameraPreviewNSView, coordinator: ()) {
        // Only unhooks the view's renderer from the feed. No capture object is involved.
        nsView.stopShowing()
    }
}

/// An NSView that shows preview frames on an AVSampleBufferDisplayLayer.
public final class CameraPreviewNSView: NSView {
    private let displayLayer: AVSampleBufferDisplayLayer
    private let renderer: PreviewRenderer
    private var feed: CameraPreviewFeed?
    private var mirrored = false

    public override init(frame frameRect: NSRect) {
        let layer = AVSampleBufferDisplayLayer()
        displayLayer = layer
        renderer = PreviewRenderer(layer.sampleBufferRenderer)
        super.init(frame: frameRect)
        wantsLayer = true
        self.layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.backgroundColor = NSColor.black.cgColor
        self.layer?.addSublayer(displayLayer)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func layout() {
        super.layout()
        placeDisplayLayer()
    }

    func show(_ feed: CameraPreviewFeed, videoGravity: AVLayerVideoGravity, mirrored: Bool) {
        if self.feed !== feed {
            self.feed?.detach(renderer)
            feed.attach(renderer)
            self.feed = feed
        }
        if displayLayer.videoGravity != videoGravity { displayLayer.videoGravity = videoGravity }
        if self.mirrored != mirrored {
            self.mirrored = mirrored
            placeDisplayLayer()
        }
    }

    func stopShowing() {
        feed?.detach(renderer)
        feed = nil
    }

    private func placeDisplayLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // bounds and position, not frame: frame is undefined under a mirroring transform.
        displayLayer.bounds = CGRect(origin: .zero, size: bounds.size)
        displayLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        displayLayer.setAffineTransform(mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity)
        CATransaction.commit()
    }
}
