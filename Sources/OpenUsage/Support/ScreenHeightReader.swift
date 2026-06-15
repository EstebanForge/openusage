import SwiftUI
import AppKit

/// Reports the usable (visibleFrame) height of the screen that currently hosts this view's window.
///
/// `NSScreen.main` is the screen with keyboard focus, which can be a different (often larger)
/// display than the one a menu-bar popover actually appears on — using it would mis-size the
/// popover. This reads the real hosting screen and updates when the window changes screens.
struct ScreenHeightReader: NSViewRepresentable {
    @Binding var usableHeight: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = TrackingView()
        view.onChange = { height in usableHeight = height }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    /// A conservative default: the shortest attached screen, so we never overflow before the real
    /// hosting screen resolves.
    static func smallestUsableHeight() -> CGFloat {
        NSScreen.screens.map(\.visibleFrame.height).min() ?? 800
    }

    final class TrackingView: NSView {
        var onChange: ((CGFloat) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Clean up any previous observer (also handles popover close: window == nil).
            if let observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                // Delivered on .main, so it's safe to assert main-actor isolation here.
                MainActor.assumeIsolated { self?.report() }
            }
            report()
        }

        private func report() {
            let screen = window?.screen ?? NSScreen.main
            guard let height = screen?.visibleFrame.height else { return }
            DispatchQueue.main.async { [weak self] in self?.onChange?(height) }
        }
    }
}
