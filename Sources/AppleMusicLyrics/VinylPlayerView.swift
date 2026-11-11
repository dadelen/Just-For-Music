import AppKit
import QuartzCore

final class VinylPlayerView: NSView {
    private static let playingNeedleAngle = -0.34
    private static let parkedNeedleAngle = 0.20
    private static let referenceBPM = 120
    private static let needleButtonRadius: CGFloat = 13

    private let record = CALayer()
    private let surface = CAGradientLayer()
    private let grooves = CAShapeLayer()
    private let cover = CALayer()
    private let spindle = CAShapeLayer()
    private let reflection = CAGradientLayer()
    private let reflectionMask = CAShapeLayer()
    private let arm = CAShapeLayer()
    private let armMidtone = CAShapeLayer()
    private let armHighlight = CAShapeLayer()
    private let cartridge = CAShapeLayer()
    private let cartridgeCap = CAShapeLayer()
    private let pivot = CAShapeLayer()
    private let pivotGlyph = CAShapeLayer()
    private let tonearmButton = TonearmButton()
    private var armHitPath: CGPath?
    private var needleHovered = false
    private var playing = false
    private var visible = false
    private var trackIdentity: String?
    private var rotationSpeed: Float = 1
    private var armEngaged = false
    private var cuePosition: Bool?
    private var artwork: NSImage?
    private var artworkNeedsUpdate = true
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
        // Rotate the composited disc as one surface. The reflection and needle stay separate.
        record.shouldRasterize = true
        reflection.shouldRasterize = true
        updateRasterizationScale()
        layer?.addSublayer(record)
        surface.colors = [NSColor(white: 0.09, alpha: 1).cgColor, NSColor(white: 0.14, alpha: 1).cgColor,
                          NSColor(white: 0.065, alpha: 1).cgColor]
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
        arm.strokeColor = NSColor(srgbRed: 0.43, green: 0.45, blue: 0.47, alpha: 1).cgColor
        arm.lineCap = .round
        arm.lineJoin = .round
        arm.anchorPoint = .zero
        arm.setValue(Self.parkedNeedleAngle, forKeyPath: "transform.rotation.z")
        arm.shadowColor = NSColor.black.cgColor
        arm.shadowOpacity = 0.26
        arm.shadowRadius = 2.2
        arm.shadowOffset = CGSize(width: 0, height: -1.2)
        for reflection in [armMidtone, armHighlight] {
            reflection.fillColor = nil
            reflection.lineCap = .round
            reflection.lineJoin = .round
            arm.addSublayer(reflection)
        }
        armMidtone.strokeColor = NSColor(srgbRed: 0.68, green: 0.69, blue: 0.71, alpha: 1).cgColor
        armHighlight.strokeColor = NSColor(white: 0.92, alpha: 0.82).cgColor
        cartridge.fillColor = NSColor(srgbRed: 0.57, green: 0.58, blue: 0.60, alpha: 1).cgColor
        cartridge.strokeColor = NSColor.black.withAlphaComponent(0.24).cgColor
        cartridge.lineWidth = 0.5
        arm.addSublayer(cartridge)
        cartridgeCap.fillColor = NSColor(srgbRed: 0.93, green: 0.92, blue: 0.88, alpha: 1).cgColor
        arm.addSublayer(cartridgeCap)
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
        rotation.duration = 12 * 60 / Double(Self.referenceBPM)
        rotation.timingFunction = CAMediaTimingFunction(name: .linear)
        rotation.repeatCount = .infinity
        rotation.isRemovedOnCompletion = false
        record.add(rotation, forKey: "rotation")
        setRotationSpeed(0)
        setAccessibilityRole(.group)
        setAccessibilityLabel("当前专辑黑胶唱片")
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(updateAnimation), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { nil }
    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

    override var mouseDownCanMoveWindow: Bool { true }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateRasterizationScale()
    }

    private func updateRasterizationScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        record.rasterizationScale = scale
        reflection.rasterizationScale = scale
    }

    func setArtwork(_ image: NSImage?) {
        guard artwork !== image else { return }
        artwork = image
        artworkNeedsUpdate = true
        if visible { updateArtwork(animated: true) }
    }

    private func updateArtwork(animated: Bool) {
        guard artworkNeedsUpdate else { return }
        artworkNeedsUpdate = false
        let image = artwork ?? NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cover.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        CATransaction.commit()
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.3
            cover.add(fade, forKey: "artwork")
        }
    }

    func update(playing: Bool, visible: Bool, trackIdentity: String? = nil, bpm: Int? = nil) {
        let tempo = bpm.flatMap { $0 > 0 ? $0 : nil } ?? Self.referenceBPM
        let speed = Float(tempo) / Float(Self.referenceBPM)
        let stateChanged = self.playing != playing
        guard stateChanged || self.visible != visible || self.trackIdentity != trackIdentity || rotationSpeed != speed else { return }
        let trackChanged = self.trackIdentity != nil && trackIdentity != nil && self.trackIdentity != trackIdentity
        let shouldAnimateTrackChange = trackChanged && self.playing && playing
            && self.visible && visible && cuePosition == nil
        self.trackIdentity = trackIdentity
        self.playing = playing
        self.visible = visible
        rotationSpeed = speed
        if visible {
            updateArtwork(animated: false)
        } else {
            setNeedleHovered(false)
            cover.removeAnimation(forKey: "artwork")
        }
        if stateChanged { updateNeedleControl() }
        updateAnimation()
        if shouldAnimateTrackChange { animateTrackChange() }
    }

    private func needleContains(_ point: NSPoint) -> Bool {
        let center = pivot.position
        if hypot(point.x - center.x, point.y - center.y) <= Self.needleButtonRadius { return true }
        guard !isNeedleButtonDetached else { return false }
        let displayedArm = arm.presentation() ?? arm
        let armPoint = displayedArm.convert(point, from: displayedArm.superlayer)
        return armHitPath?.contains(armPoint) ?? false
    }

    var isNeedleButtonDetached: Bool { tonearmButton.superview !== self }

    var needleButtonFrame: NSRect {
        let radius = Self.needleButtonRadius
        return NSRect(x: arm.position.x - radius, y: arm.position.y - radius,
                      width: radius * 2, height: radius * 2)
    }

    func placeNeedleButton(in container: NSView) {
        guard tonearmButton.superview !== container else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tonearmButton.removeFromSuperview()
        for layer in [pivot, pivotGlyph] {
            layer.removeFromSuperlayer()
            container.layer?.addSublayer(layer)
        }
        container.addSubview(tonearmButton)
        layoutNeedleButton()
        setNeedleHovered(false)
        CATransaction.commit()
    }

    private func layoutNeedleButton() {
        guard let container = tonearmButton.superview else { return }
        tonearmButton.frame = container.bounds
        let center = isNeedleButtonDetached
            ? CGPoint(x: container.bounds.midX, y: container.bounds.midY) : arm.position
        pivot.position = center
        pivotGlyph.position = center
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
        pivot.fillColor = NSColor(white: needleHovered ? 0.94 : 0.78, alpha: 1).cgColor
        pivotGlyph.isHidden = !allowsPlaybackControl
        let glyph = CGMutablePath()
        if playing {
            glyph.addRoundedRect(in: CGRect(x: -3.2, y: -3.6, width: 2, height: 7.2), cornerWidth: 0.7, cornerHeight: 0.7)
            glyph.addRoundedRect(in: CGRect(x: 1.2, y: -3.6, width: 2, height: 7.2), cornerWidth: 0.7, cornerHeight: 0.7)
        } else {
            glyph.move(to: CGPoint(x: -2.3, y: -4))
            glyph.addLine(to: CGPoint(x: 4.3, y: 0))
            glyph.addLine(to: CGPoint(x: -2.3, y: 4))
            glyph.closeSubpath()
        }
        pivotGlyph.path = glyph
        CATransaction.commit()
    }

    @objc private func updateAnimation() {
        let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        setRotationSpeed(playing && visible && !reducedMotion ? rotationSpeed : 0)
        moveNeedle(ontoRecord: cuePosition ?? playing)
    }

    func cueNeedle(ontoRecord: Bool) async {
        await withCheckedContinuation { continuation in
            cuePosition = ontoRecord
            moveNeedle(ontoRecord: ontoRecord) { continuation.resume() }
        }
    }

    func followPlayback() {
        cuePosition = nil
        updateAnimation()
    }

    private var displayedNeedleAngle: Double? {
        (arm.presentation()?.value(forKeyPath: "transform.rotation.z") as? Double)
            ?? (arm.value(forKeyPath: "transform.rotation.z") as? Double)
    }

    private func animateTrackChange() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let playingAngle = Self.playingNeedleAngle
        let parkedAngle = Self.parkedNeedleAngle
        let animation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        animation.values = [displayedNeedleAngle ?? playingAngle, parkedAngle, parkedAngle, playingAngle]
        animation.keyTimes = [0, 0.36, 0.52, 1]
        animation.timingFunctions = [
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(name: .easeInEaseOut)
        ]
        animation.duration = 0.84
        arm.add(animation, forKey: "needle")
    }

    private func moveNeedle(ontoRecord: Bool, completion: (() -> Void)? = nil) {
        let animate = visible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let alreadyMoving = arm.animation(forKey: "needle") != nil
        if !animate { arm.removeAnimation(forKey: "needle") }
        guard armEngaged != ontoRecord || (animate && alreadyMoving && completion != nil) else {
            completion?()
            return
        }
        armEngaged = ontoRecord
        let angle = ontoRecord ? Self.playingNeedleAngle : Self.parkedNeedleAngle
        let previous = displayedNeedleAngle ?? angle
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arm.setValue(angle, forKeyPath: "transform.rotation.z")
        if animate {
            if let completion {
                CATransaction.setCompletionBlock { DispatchQueue.main.async(execute: completion) }
            }
            let animation = CABasicAnimation(keyPath: "transform.rotation.z")
            animation.fromValue = previous
            animation.toValue = angle
            let fullDuration = completion == nil ? 0.60 : (ontoRecord ? 0.44 : 0.30)
            animation.duration = max(0.04, fullDuration * min(1, abs(previous - angle) / 0.54))
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            arm.add(animation, forKey: "needle")
        }
        CATransaction.commit()
        if !animate { completion?() }
    }

    private func setRotationSpeed(_ speed: Float) {
        guard record.speed != speed else { return }
        let now = CACurrentMediaTime()
        let localTime = record.convertTime(now, from: nil)
        let parentTime = record.superlayer?.convertTime(now, from: nil) ?? now
        // Rebase the clock so a new rate starts at the current rotation phase.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        record.speed = speed
        if speed == 0 {
            record.timeOffset = localTime
        } else {
            record.timeOffset = 0
            record.beginTime = parentTime - localTime / Double(speed)
        }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        let diameter = min(bounds.width - 28, (bounds.height - 26) / 1.08)
        guard diameter > 0 else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY - diameter * 0.04)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        record.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        record.position = center
        record.cornerRadius = diameter / 2
        let discFrame = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
        surface.frame = record.bounds
        surface.cornerRadius = diameter / 2
        let rings = CGMutablePath()
        for index in 0..<24 {
            let inset = diameter * (0.008 + CGFloat(index) * 0.004)
            rings.addEllipse(in: record.bounds.insetBy(dx: inset, dy: inset))
        }
        grooves.frame = record.bounds
        grooves.path = rings
        let coverInset = diameter * 0.11
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
        let tip = CGPoint(x: diameter * 0.56, y: -diameter * 0.28)
        needle.addLine(to: tip)
        arm.path = needle
        arm.lineWidth = min(6, max(2.8, diameter * 0.017))
        armMidtone.path = needle
        armMidtone.lineWidth = arm.lineWidth * 0.72
        armMidtone.position.y = arm.lineWidth * 0.08
        armHighlight.path = needle
        armHighlight.lineWidth = arm.lineWidth * 0.24
        armHighlight.position.y = arm.lineWidth * 0.25
        armHitPath = needle.copy(strokingWithWidth: 24, lineCap: .round, lineJoin: .round, miterLimit: 1)
        let headWidth = min(16, max(10, diameter * 0.061))
        let headHeight = min(6, max(4.5, diameter * 0.027))
        var headTransform = CGAffineTransform(translationX: tip.x, y: tip.y).rotated(by: -0.185)
        let head = CGPath(roundedRect: CGRect(x: -headWidth * 0.65, y: -headHeight / 2, width: headWidth, height: headHeight),
                          cornerWidth: 1.4, cornerHeight: 1.4, transform: nil)
        cartridge.path = head.copy(using: &headTransform)
        let capWidth = headWidth * 0.30
        let cap = CGPath(roundedRect: CGRect(x: headWidth * 0.35 - capWidth - 0.35, y: -headHeight / 2 + 0.5,
                                           width: capWidth, height: headHeight - 1),
                         cornerWidth: 1, cornerHeight: 1, transform: nil)
        cartridgeCap.path = cap.copy(using: &headTransform)
        let shadowPath = CGMutablePath()
        shadowPath.addPath(needle.copy(strokingWithWidth: arm.lineWidth, lineCap: .round, lineJoin: .round, miterLimit: 1))
        if let headPath = cartridge.path { shadowPath.addPath(headPath) }
        arm.shadowPath = shadowPath
        pivot.path = CGPath(ellipseIn: CGRect(x: -9, y: -9, width: 18, height: 18), transform: nil)
        pivot.shadowPath = pivot.path
        layoutNeedleButton()
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
