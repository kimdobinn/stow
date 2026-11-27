import AVKit
import os
import SwiftUI
import UIKit

/// The view the video draws in. There's one, owned by the player: the watch page and the mini
/// player each take it when they appear (see `VideoSurface`), so Picture in Picture keeps one layer.
final class PlayerVideoView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// Shows the player's video here. Whichever surface last appeared on screen holds it.
struct VideoSurface: UIViewRepresentable {
    let controller: PlaybackController
    var fill = false

    func makeUIView(context: Context) -> Holder {
        let holder = Holder(video: controller.videoView)
        holder.fill = fill
        return holder
    }

    func updateUIView(_ holder: Holder, context: Context) {
        holder.fill = fill
        holder.adopt()
    }

    final class Holder: UIView {
        let video: PlayerVideoView
        var fill = false {
            didSet { if fill != oldValue, video.superview === self { video.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect } }
        }

        init(video: PlayerVideoView) {
            self.video = video
            super.init(frame: .zero)
            backgroundColor = .black
            clipsToBounds = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { adopt() }
        }

        func adopt() {
            guard window != nil, video.superview !== self else { return }
            video.removeFromSuperview()
            video.frame = bounds
            video.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            video.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
            addSubview(video)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if video.superview === self { video.frame = bounds }
        }
    }
}

/// Picture in Picture for the player's one layer: from the button, or on its own when you leave
/// the app while a video plays on the watch page.
@MainActor
final class PictureInPicture: NSObject, AVPictureInPictureControllerDelegate {
    private weak var controller: PlaybackController?
    private let pip: AVPictureInPictureController?

    init(controller: PlaybackController) {
        self.controller = controller
        pip = AVPictureInPictureController.isPictureInPictureSupported()
            ? AVPictureInPictureController(playerLayer: controller.videoView.playerLayer) : nil
        super.init()
        if pip == nil { Logger(subsystem: "dev.stow.ios", category: "player").info("Picture in Picture isn't supported here") }
        pip?.delegate = self
        // Leaving the app while a video plays on screen floats it, as on YouTube.
        pip?.canStartPictureInPictureAutomaticallyFromInline = true
    }

    var isSupported: Bool { pip != nil }

    func toggle() {
        guard let pip else { return }
        if pip.isPictureInPictureActive { pip.stopPictureInPicture() } else { pip.startPictureInPicture() }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        MainActor.assumeIsolated { controller?.pictureInPictureChanged(true) }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        MainActor.assumeIsolated { controller?.pictureInPictureChanged(false) }
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        MainActor.assumeIsolated { controller?.restoreFromPictureInPicture() }
        completionHandler(true)
    }
}
