import AppKit
import SwiftUI

/// Centers the window's close, minimize and zoom buttons in the custom title bar. AppKit places them
/// for its own title bar, which is shorter than this app's, so they sat above the wordmark's line.
/// The title bar container is grown to the same height, so the whole bar also drags the window.
struct TrafficLightAligner: NSViewRepresentable {
    let barHeight: CGFloat

    func makeNSView(context: Context) -> AlignerView {
        let view = AlignerView()
        view.barHeight = barHeight
        return view
    }

    func updateNSView(_ view: AlignerView, context: Context) {
        view.barHeight = barHeight
        view.align()
    }

    final class AlignerView: NSView {
        var barHeight: CGFloat = 48
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {

            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification, NSWindow.didEnterFullScreenNotification,
                NSWindow.didExitFullScreenNotification, NSWindow.didChangeScreenNotification
            ]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.align() }
                })
            }
            align()
            // AppKit finishes its own title bar layout after this view lands; go once more after it.
            DispatchQueue.main.async { [weak self] in self?.align() }
        }

        override func layout() {
            super.layout()
            align()
        }

        func align() {
            guard let window, !window.styleMask.contains(.fullScreen) else { return }
            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
                .compactMap { window.standardWindowButton($0) }
            guard let first = buttons.first,
                  let titlebar = first.superview,
                  let container = titlebar.superview,
                  let frame = container.superview else { return }

            // Grow the title bar container to the custom bar's height, anchored at the top.
            var containerFrame = container.frame
            if abs(containerFrame.height - barHeight) > 0.5 || abs(containerFrame.maxY - frame.bounds.maxY) > 0.5 {
                containerFrame.size.height = barHeight
                containerFrame.origin.y = frame.bounds.maxY - barHeight
                container.frame = containerFrame
            }
            var titlebarFrame = titlebar.frame
            if abs(titlebarFrame.height - barHeight) > 0.5 || titlebarFrame.origin.y != 0 {
                titlebarFrame.size.height = barHeight
                titlebarFrame.origin.y = 0
                titlebar.frame = titlebarFrame
            }

            for button in buttons {
                var buttonFrame = button.frame
                let centered = (barHeight - buttonFrame.height) / 2
                if abs(buttonFrame.origin.y - centered) > 0.5 {
                    buttonFrame.origin.y = centered
                    button.frame = buttonFrame
                }
            }
        }
    }
}
