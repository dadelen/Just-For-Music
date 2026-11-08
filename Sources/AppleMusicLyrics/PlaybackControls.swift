import AppKit

final class PlaybackControls: NSView {
    private let previous = ActionButton()
    private let play = ActionButton()
    private let next = ActionButton()
    private let buttonWidth: CGFloat
    private let grouped: Bool
    private var playing = false

    var onPrevious: (() -> Void)? { didSet { previous.onPress = onPrevious } }
    var onToggle: (() -> Void)? { didSet { play.onPress = onToggle } }
    var onNext: (() -> Void)? { didSet { next.onPress = onNext } }
    var width: CGFloat { 3 * buttonWidth }
    private var buttons: [ActionButton] { [previous, play, next] }

    init(buttonWidth: CGFloat, grouped: Bool = false) {
        self.buttonWidth = buttonWidth
        self.grouped = grouped
        super.init(frame: .zero)
        previous.setSymbol("backward.fill", label: "上一首")
        play.setSymbol("play.fill", label: "播放")
        next.setSymbol("forward.fill", label: "下一首")
        for button in buttons {
            button.isEnabled = false
            addSubview(button)
        }
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: CGFloat(index) * buttonWidth, y: 0, width: buttonWidth, height: bounds.height)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard grouped else { return }
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }

    func update(_ track: TrackInfo?) {
        for button in buttons where button.isEnabled != (track != nil) {
            button.isEnabled = track != nil
        }
        let isPlaying = track?.state == .playing
        guard playing != isPlaying else { return }
        playing = isPlaying
        play.setSymbol(isPlaying ? "pause.fill" : "play.fill", label: isPlaying ? "暂停" : "播放")
    }

    /// Dispatch a click received by the system status button to its displayed segment.
    func activate(at point: NSPoint) -> Bool {
        guard !isHidden, bounds.contains(point) else { return false }
        let button = buttons[min(buttons.count - 1, Int(point.x / buttonWidth))]
        if button.isEnabled { button.onPress?() }
        return true
    }

    var accessibilityActions: [NSAccessibilityCustomAction] {
        guard !isHidden else { return [] }
        return buttons.compactMap { button in
            guard button.isEnabled, let label = button.accessibilityLabel() else { return nil }
            return NSAccessibilityCustomAction(name: label) { [weak button] in
                guard let button, button.isEnabled else { return false }
                button.onPress?()
                return true
            }
        }
    }
}
