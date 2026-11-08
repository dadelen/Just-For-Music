import AppKit
import QuartzCore

final class PanelFade {
    private var revision = 0
    private(set) var isClosing = false

    func show(_ panel: NSWindow, animated: Bool = true, orderFront: () -> Void) {
        revision += 1
        let openingRevision = revision
        isClosing = false
        let animate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !panel.isVisible { panel.alphaValue = animate ? 0 : 1 }
        orderFront()
        fade(panel, to: 1, duration: animate ? 0.23 : 0) { [weak self, weak panel] in
            guard self?.revision == openingRevision else { return }
            // The floating controls can be attached while the parent is fading in.
            panel?.childWindows?.forEach { $0.alphaValue = 1 }
        }
    }

    func hide(_ panel: NSWindow, animated: Bool = true, completion: @escaping () -> Void = {}) {
        guard panel.isVisible, !isClosing else { return }
        revision += 1
        let closingRevision = revision
        isClosing = true
        let animate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        fade(panel, to: 0, duration: animate ? 0.17 : 0) { [weak self, weak panel] in
            guard let self, self.revision == closingRevision else { return }
            panel?.orderOut(nil)
            self.isClosing = false
            completion()
        }
    }

    private func fade(_ panel: NSWindow, to alpha: CGFloat, duration: TimeInterval, completion: @escaping () -> Void = {}) {
        let windows = [panel] + (panel.childWindows ?? [])
        guard duration > 0 else {
            for window in windows { window.alphaValue = alpha }
            completion()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            for window in windows { window.animator().alphaValue = alpha }
        }, completionHandler: completion)
    }
}
