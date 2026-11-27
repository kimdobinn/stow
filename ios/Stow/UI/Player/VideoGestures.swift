import SwiftUI
import UIKit

/// The video's touches, in UIKit for exact timing: a tap reports at once (no waiting to rule out
/// a double tap, which the player works out itself), a hold reports when it starts and ends, and
/// an up or down drag reports as it moves and how fast it ended.
struct VideoGestures: UIViewRepresentable {
    var onTap: (CGPoint, CGSize) -> Void
    var onHold: (Bool) -> Void
    /// Vertical drag: the distance so far (down is positive), and when it ends, its speed.
    var onDrag: (CGFloat) -> Void
    var onDragEnd: (CGFloat, CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let coordinator = context.coordinator
        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tapped(_:)))
        let hold = UILongPressGestureRecognizer(target: coordinator, action: #selector(Coordinator.held(_:)))
        hold.minimumPressDuration = 0.4
        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.panned(_:)))
        pan.delegate = coordinator
        [tap, hold, pan].forEach(view.addGestureRecognizer)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: VideoGestures?

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view else { return }
            parent?.onTap(gesture.location(in: view), view.bounds.size)
        }

        @objc func held(_ gesture: UILongPressGestureRecognizer) {
            switch gesture.state {
            case .began: parent?.onHold(true)
            case .ended, .cancelled, .failed: parent?.onHold(false)
            default: break
            }
        }

        @objc func panned(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            switch gesture.state {
            case .changed: parent?.onDrag(gesture.translation(in: view).y)
            case .ended, .cancelled: parent?.onDragEnd(gesture.translation(in: view).y, gesture.velocity(in: view).y)
            default: break
            }
        }

        /// Only up and down: sideways belongs to the seek bar.
        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard let pan = gesture as? UIPanGestureRecognizer, let view = pan.view else { return true }
            let velocity = pan.velocity(in: view)
            return abs(velocity.y) > abs(velocity.x)
        }
    }
}
