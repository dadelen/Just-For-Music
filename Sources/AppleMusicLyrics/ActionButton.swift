import AppKit

final class ActionButton: NSButton {
    var onPress: (() -> Void)?
    private var hoverArea: NSTrackingArea?

    init(title: String = "", action: (() -> Void)? = nil) {
        super.init(frame: .zero)
        self.title = title
        onPress = action
        target = self
        self.action = #selector(performPress)
        isBordered = false
        bezelStyle = .accessoryBarAction
        font = .systemFont(ofSize: 12, weight: .medium)
        wantsLayer = true
        layer?.cornerRadius = 12
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { nil }

    func setSymbol(_ symbol: String, label: String) {
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        imagePosition = .imageOnly
        toolTip = label
        setAccessibilityLabel(label)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
    }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = nil }
    @objc private func performPress() { onPress?() }
}
