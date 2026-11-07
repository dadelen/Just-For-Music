import AppKit

/// A single system material with an independent content container.
final class GlassSurface: NSView {
    let content = NSView()
    private var material: NSView?
    private let corner: CGFloat

    init(cornerRadius: CGFloat = 24) {
        corner = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = corner
        layer?.masksToBounds = true
        rebuildMaterial()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(rebuildMaterial), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { nil }
    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

    @objc private func rebuildMaterial() {
        content.removeFromSuperview()
        material?.removeFromSuperview()
        material = nil
        layer?.backgroundColor = nil
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            addSubview(content)
        } else {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                let glass = NSGlassEffectView()
                glass.cornerRadius = corner
                glass.style = .regular
                glass.contentView = content
                addSubview(glass)
                material = glass
            } else {
                installLegacyMaterial()
            }
            #else
            installLegacyMaterial()
            #endif
        }
        needsLayout = true
    }

    private func installLegacyMaterial() {
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        addSubview(effect)
        addSubview(content)
        material = effect
        updateOpacity()
    }

    func updateOpacity() {
        (material as? NSVisualEffectView)?.alphaValue = CGFloat(AppPreferences.floatingLyricsOpacity)
    }

    override func layout() {
        super.layout()
        material?.frame = bounds
        content.frame = bounds
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }
}
