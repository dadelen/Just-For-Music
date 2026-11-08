import AppKit
import QuartzCore

final class VinylPlayerView: NSView {
    private let record = CALayer()
    private let surface = CAGradientLayer()
    private let grooves = CAShapeLayer()
    private let cover = CALayer()
    private let spindle = CAShapeLayer()
    private let recordShadow = CALayer()
    private let reflection = CAGradientLayer()
    private let reflectionMask = CAShapeLayer()
    private let arm = CAShapeLayer()
    private let cartridge = CAShapeLayer()
    private let pivot = CAShapeLayer()
    private let pivotGlyph = CAShapeLayer()
    private let tonearmButton = TonearmButton()
    private var armHitPath: CGPath?
    private var needleHovered = false
    private var playing = false
    private var visible = false
    private var armEngaged = false
    var onTogglePlayPause: (() -> Void)?
    var allowsPlaybackControl = false {
        didSet {
            guard oldValue != allowsPlaybackControl else { return }
            tonearmButton.isEnabled = allowsPlaybackControl
            if !allowsPlaybackControl { setNeedleHovered(false) }
            updateNeedleControl()
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(record)
        recordShadow.backgroundColor = NSColor.black.cgColor
        recordShadow.shadowColor = NSColor.black.cgColor
        recordShadow.shadowOpacity = 0.32
        recordShadow.shadowRadius = 9
        recordShadow.shadowOffset = CGSize(width: 0, height: -4)
        layer?.insertSublayer(recordShadow, below: record)
        surface.colors = [NSColor(white: 0.05, alpha: 1).cgColor, NSColor(white: 0.08, alpha: 1).cgColor,
                          NSColor(white: 0.035, alpha: 1).cgColor]
        surface.startPoint = CGPoint(x: 0, y: 0)
        surface.endPoint = CGPoint(x: 1, y: 1)
        record.addSublayer(surface)
        grooves.fillColor = nil
        grooves.strokeColor = NSColor.white.withAlphaComponent(0.065).cgColor
        grooves.lineWidth = 0.55
        record.addSublayer(grooves)
        cover.masksToBounds = true
        cover.contentsGravity = .resizeAspectFill
        record.addSublayer(cover)
        spindle.fillColor = NSColor(white: 0.12, alpha: 1).cgColor
        record.addSublayer(spindle)
        record.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        record.borderWidth = 0.75

        // The light stays still as the grooves and album cover rotate beneath it.
        reflection.colors = [0.23, 0.09, 0.0, 0.0, 0.13].map { NSColor.white.withAlphaComponent($0).cgColor }
        reflection.locations = [0, 0.24, 0.47, 0.63, 1]
        reflection.startPoint = CGPoint(x: 0.13, y: 0.93)
        reflection.endPoint = CGPoint(x: 0.85, y: 0.07)
        reflectionMask.fillRule = .evenOdd
        reflection.mask = reflectionMask
        layer?.addSublayer(reflection)

        arm.fillColor = nil
        arm.strokeColor = NSColor(white: 0.94, alpha: 1).cgColor
        arm.lineCap = .round
        arm.lineJoin = .round
        arm.anchorPoint = .zero
        arm.setValue(0.20, forKeyPath: "transform.rotation.z")
        arm.shadowColor = NSColor.black.cgColor
        arm.shadowOpacity = 0.32
        arm.shadowRadius = 2
        arm.shadowOffset = CGSize(width: 0, height: -1)
        cartridge.fillColor = NSColor(white: 0.98, alpha: 1).cgColor
        cartridge.strokeColor = NSColor.black.withAlphaComponent(0.18).cgColor
        cartridge.lineWidth = 0.75
        arm.addSublayer(cartridge)
        layer?.addSublayer(arm)
        pivot.strokeColor = NSColor.black.withAlphaComponent(0.17).cgColor
        pivot.lineWidth = 1
        pivot.shadowColor = NSColor.black.cgColor
        pivot.shadowOpacity = 0.28
        pivot.shadowRadius = 2
        pivot.shadowOffset = CGSize(width: 0, height: -1)
        layer?.addSublayer(pivot)
        pivotGlyph.fillColor = NSColor(white: 0.25, alpha: 1).cgColor
        layer?.addSublayer(pivotGlyph)
        tonearmButton.isEnabled = false
        tonearmButton.containsLocation = { [weak self] point in self?.needleContains(point) ?? false }
        tonearmButton.onHover = { [weak self] hovered in self?.setNeedleHovered(hovered) }
        tonearmButton.onPress = { [weak self] in self?.onTogglePlayPause?() }
        addSubview(tonearmButton)
        updateNeedleControl()
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = -2 * Double.pi
        rotation.duration = 6
        rotation.timingFunction = CAMediaTimingFunction(name: .linear)
        rotation.repeatCount = .infinity
        rotation.isRemovedOnCompletion = false
        record.add(rotation, forKey: "rotation")
        pauseRotation()
        setArtwork(nil)
        setAccessibilityRole(.group)
        setAccessibilityLabel("当前专辑黑胶唱片")
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(updateAnimation), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { nil }
    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

    override var mouseDownCanMoveWindow: Bool { true }

    func setArtwork(_ image: NSImage?) {
        let image = image ?? NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cover.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        CATransaction.commit()
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.3
            cover.add(fade, forKey: "artwork")
        }
    }

    func update(playing: Bool, visible: Bool) {
        let stateChanged = self.playing != playing
        self.playing = playing
        self.visible = visible
        if !visible { setNeedleHovered(false) }
        if stateChanged { updateNeedleControl() }
        updateAnimation()
    }

    private func needleContains(_ point: NSPoint) -> Bool {
        if hypot(point.x - arm.position.x, point.y - arm.position.y) <= 13 { return true }
        let displayedArm = arm.presentation() ?? arm
        let armPoint = displayedArm.convert(point, from: displayedArm.superlayer)
        return armHitPath?.contains(armPoint) ?? false
    }

    private func setNeedleHovered(_ hovered: Bool) {
        guard needleHovered != hovered else { return }
        needleHovered = hovered
        updateNeedleControl()
    }

    private func updateNeedleControl() {
        let label = playing ? "唱针，暂停" : "唱针，播放"
        tonearmButton.setAccessibilityLabel(label)
        tonearmButton.toolTip = needleHovered ? label : nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pivot.fillColor = (needleHovered ? NSColor.white : NSColor(white: 0.90, alpha: 1)).cgColor
        pivotGlyph.isHidden = !allowsPlaybackControl
        let point = arm.position
        let glyph = CGMutablePath()
        if playing {
            glyph.addRoundedRect(in: CGRect(x: point.x - 3.2, y: point.y - 3.6, width: 2, height: 7.2), cornerWidth: 0.7, cornerHeight: 0.7)
            glyph.addRoundedRect(in: CGRect(x: point.x + 1.2, y: point.y - 3.6, width: 2, height: 7.2), cornerWidth: 0.7, cornerHeight: 0.7)
        } else {
            glyph.move(to: CGPoint(x: point.x - 2.3, y: point.y - 4))
            glyph.addLine(to: CGPoint(x: point.x + 4.3, y: point.y))
            glyph.addLine(to: CGPoint(x: point.x - 2.3, y: point.y + 4))
            glyph.closeSubpath()
        }
        pivotGlyph.path = glyph
        CATransaction.commit()
    }

    @objc private func updateAnimation() {
        let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if playing && visible && !reducedMotion { resumeRotation() } else { pauseRotation() }
        guard armEngaged != playing else { return }
        armEngaged = playing
        let angle: CGFloat = playing ? -0.34 : 0.20
        let previous = arm.presentation()?.value(forKeyPath: "transform.rotation.z") ?? arm.value(forKeyPath: "transform.rotation.z")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arm.setValue(angle, forKeyPath: "transform.rotation.z")
        CATransaction.commit()
        if visible && !reducedMotion {
            let animation = CABasicAnimation(keyPath: "transform.rotation.z")
            animation.fromValue = previous
            animation.toValue = angle
            animation.duration = 0.60
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            arm.add(animation, forKey: "needle")
        }
    }

    private func pauseRotation() {
        guard record.speed != 0 else { return }
        let time = record.convertTime(CACurrentMediaTime(), from: nil)
        record.speed = 0
        record.timeOffset = time
    }

    private func resumeRotation() {
        guard record.speed == 0 else { return }
        let paused = record.timeOffset
        record.speed = 1
        record.timeOffset = 0
        record.beginTime = 0
        record.beginTime = record.convertTime(CACurrentMediaTime(), from: nil) - paused
    }

    override func layout() {
        super.layout()
        tonearmButton.frame = bounds
        let diameter = min(bounds.width - 28, (bounds.height - 26) / 1.08)
        guard diameter > 0 else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY - diameter * 0.04)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        record.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        record.position = center
        record.cornerRadius = diameter / 2
        let discFrame = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
        recordShadow.frame = discFrame
        recordShadow.cornerRadius = diameter / 2
        recordShadow.shadowPath = CGPath(ellipseIn: recordShadow.bounds, transform: nil)
        surface.frame = record.bounds
        surface.cornerRadius = diameter / 2
        let rings = CGMutablePath()
        for index in 0..<30 {
            let inset = CGFloat(index) * diameter * 0.004 + 3
            rings.addEllipse(in: record.bounds.insetBy(dx: inset, dy: inset))
        }
        grooves.frame = record.bounds
        grooves.path = rings
        let coverInset = diameter * 0.17
        cover.frame = record.bounds.insetBy(dx: coverInset, dy: coverInset)
        cover.cornerRadius = cover.bounds.width / 2
        cover.backgroundColor = NSColor(white: 0.22, alpha: 1).cgColor
        reflection.frame = discFrame
        reflectionMask.frame = reflection.bounds
        let annulus = CGMutablePath()
        annulus.addEllipse(in: reflection.bounds)
        annulus.addEllipse(in: cover.frame)
        reflectionMask.path = annulus
        spindle.path = CGPath(ellipseIn: CGRect(x: diameter / 2 - 2, y: diameter / 2 - 2, width: 4, height: 4), transform: nil)
        let pivotPoint = CGPoint(x: center.x - diameter * 0.03, y: center.y + diameter * 0.58)
        arm.position = pivotPoint
        arm.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        let needle = CGMutablePath()
        needle.move(to: .zero)
        needle.addCurve(to: CGPoint(x: diameter * 0.32, y: -diameter * 0.25),
                        control1: CGPoint(x: diameter * 0.12, y: -diameter * 0.12),
                        control2: CGPoint(x: diameter * 0.21, y: -diameter * 0.23))
        let tip = CGPoint(x: diameter * 0.48, y: -diameter * 0.28)
        needle.addLine(to: tip)
        arm.path = needle
        arm.lineWidth = max(3.5, diameter * 0.020)
        arm.shadowPath = needle.copy(strokingWithWidth: arm.lineWidth, lineCap: .round, lineJoin: .round, miterLimit: 1)
        armHitPath = needle.copy(strokingWithWidth: 24, lineCap: .round, lineJoin: .round, miterLimit: 1)
        let headWidth = max(13, diameter * 0.08)
        var headTransform = CGAffineTransform(translationX: tip.x, y: tip.y).rotated(by: -0.185)
        let head = CGPath(roundedRect: CGRect(x: -headWidth * 0.65, y: -3.5, width: headWidth, height: 7),
                          cornerWidth: 2, cornerHeight: 2, transform: nil)
        cartridge.path = head.copy(using: &headTransform)
        pivot.path = CGPath(ellipseIn: CGRect(x: pivotPoint.x - 9, y: pivotPoint.y - 9, width: 18, height: 18), transform: nil)
        pivot.shadowPath = pivot.path
        updateNeedleControl()
        CATransaction.commit()
    }
}

private final class TonearmButton: ActionButton {
    var containsLocation: ((NSPoint) -> Bool)?
    var onHover: ((Bool) -> Void)?
    private var moveTracking: NSTrackingArea?
    private var pressed = false

    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // The arm path uses the vinyl view's coordinates.
        guard isEnabled, containsLocation?(point) == true else { return nil }
        return super.hitTest(point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let moveTracking { removeTrackingArea(moveTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        moveTracking = area
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseMoved(with event: NSEvent) {
        let hovered = contains(event)
        onHover?(hovered)
        (hovered ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        pressed = contains(event)
    }

    override func mouseUp(with event: NSEvent) {
        let activate = pressed && contains(event)
        pressed = false
        if activate { performClick(nil) }
    }

    private func contains(_ event: NSEvent) -> Bool {
        guard isEnabled, let superview else { return false }
        return containsLocation?(superview.convert(event.locationInWindow, from: nil)) == true
    }
}
