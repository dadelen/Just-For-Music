import AppKit

/// A single system material with an independent content container.
final class GlassSurface: NSView {
    let content = NSView()
    private var material: NSView?
    private let corner: CGFloat
    private let clearGlass: Bool
    private let adjustableOpacity: Bool
    var backgroundOpacity: CGFloat = 1 {
        didSet { updateMaterialOpacity() }
    }

    init(cornerRadius: CGFloat = 24, clearGlass: Bool = false, adjustableOpacity: Bool = false) {
        corner = cornerRadius
        self.clearGlass = clearGlass
        self.adjustableOpacity = adjustableOpacity
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
        layer?.masksToBounds = true
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            addSubview(content)
        } else {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                let glass = NSGlassEffectView()
                glass.cornerRadius = corner
                glass.style = clearGlass ? .clear : .regular
                glass.contentView = adjustableOpacity ? NSView() : content
                addSubview(glass)
                // Adjustable glass sits behind its content so text keeps its full opacity.
                if adjustableOpacity {
                    // The floating controls are inset and the glass owns its rounded clip.
                    layer?.masksToBounds = false
                    addSubview(content)
                }
                material = glass
            } else {
                installLegacyMaterial()
            }
            #else
            installLegacyMaterial()
            #endif
        }
        updateMaterialOpacity()
        needsLayout = true
    }

    private func updateMaterialOpacity() {
        guard adjustableOpacity, let material else { return }
        material.alphaValue = backgroundOpacity
        material.isHidden = backgroundOpacity == 0
    }

    private func installLegacyMaterial() {
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        addSubview(effect)
        addSubview(content)
        material = effect
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
