import AppKit
import QuartzCore

final class VinylPlayerView: NSView {
    private static let referenceBPM = 120
    private static let needleButtonRadius: CGFloat = 13

    private let recordShadow = CALayer()
    private let record = CALayer()
    private let surface = CALayer()
    private let labelRing = CAShapeLayer()
    private let cover = CALayer()
    private let spindle = CAShapeLayer()
    private let reflection = CALayer()
    private let rim = CAShapeLayer()
    private let arm = CAShapeLayer()
    private let armMaterial = CALayer()
    private let pivotMaterial = CALayer()
    private let pivot = CAShapeLayer()
    private let pivotGlyph = CAShapeLayer()
    private let tonearmButton = TonearmButton()
    private var armHitPath: CGPath?
    private var needleHovered = false
    private var playing = false
    private var visible = false
    private var trackIdentity: String?
    private var rotationSpeed: Float = 1
    private var geometry: VinylTonearmGeometry?
    private var playbackClock = VinylPlaybackClock()
    private var cueHoldPosition: TimeInterval?
    private var textureKey: String?
    private var laidOutSize = NSSize.zero
    private var laidOutScale: CGFloat = 0
    private var isInLiveResize = false
    private var needsMaterialRefresh = false
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
        // Static grooves and illumination are bitmaps; only the disc transform rotates.
        recordShadow.name = "vinyl.recordShadow"
        recordShadow.shadowColor = NSColor.black.cgColor
        recordShadow.shadowOpacity = 0.22
        recordShadow.shadowRadius = 2
        recordShadow.shadowOffset = CGSize(width: 0, height: -2)
        layer?.addSublayer(recordShadow)
        record.name = "vinyl.record"
        cover.name = "vinyl.label"
        reflection.name = "vinyl.environmentLight"
        arm.name = "vinyl.tonearm"
        layer?.addSublayer(record)
        record.addSublayer(surface)
        labelRing.fillColor = NSColor(white: 0.1, alpha: 1).cgColor
        labelRing.strokeColor = NSColor(white: 0.66, alpha: 0.65).cgColor
        labelRing.lineWidth = 0.65
        record.addSublayer(labelRing)
        cover.masksToBounds = true
        cover.contentsGravity = .resizeAspectFill
        cover.backgroundColor = NSColor(white: 0.22, alpha: 1).cgColor
        record.addSublayer(cover)
        spindle.fillColor = NSColor(white: 0.8, alpha: 1).cgColor
        spindle.strokeColor = NSColor(white: 0.13, alpha: 1).cgColor
        spindle.lineWidth = 0.7
        record.addSublayer(spindle)
        layer?.addSublayer(reflection)
        rim.fillColor = nil
        rim.strokeColor = NSColor(white: 0.7, alpha: 0.26).cgColor
        rim.lineWidth = 0.65
        layer?.addSublayer(rim)

        // Geometry/hit testing lives on the parent; all static metal shading
        // is baked into one child bitmap rather than stacked highlight strokes.
        arm.fillColor = nil
        arm.strokeColor = NSColor.clear.cgColor
        arm.lineCap = .round
        arm.lineJoin = .round
        arm.anchorPoint = .zero
        arm.shadowColor = NSColor.black.cgColor
        arm.shadowOpacity = 0.15
        arm.shadowRadius = 1.4
        arm.shadowOffset = CGSize(width: 0.7, height: -1)
        arm.addSublayer(armMaterial)
        pivot.addSublayer(pivotMaterial)
        layer?.addSublayer(arm)
        pivot.strokeColor = nil
        pivot.lineWidth = 1
        pivot.shadowColor = NSColor.black.cgColor
        pivot.shadowOpacity = 0.20
        pivot.shadowRadius = 2
        pivot.shadowOffset = CGSize(width: 0, height: -1)
        pivotMaterial.frame = CGRect(x: -11, y: -11, width: 22, height: 22)
        pivot.path = CGPath(ellipseIn: pivotMaterial.frame, transform: nil)
        pivot.shadowPath = pivot.path
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
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(accessibilityAnimationChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { nil }
    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

    override var mouseDownCanMoveWindow: Bool { true }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        isInLiveResize = true
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        isInLiveResize = false
        needsMaterialRefresh = true
        needsLayout = true
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

    func update(playing: Bool, visible: Bool, trackIdentity: String? = nil, bpm: Int? = nil,
                position: TimeInterval? = nil, duration: TimeInterval? = nil) {
        if geometry == nil { layoutSubtreeIfNeeded() }
        let tempo = bpm.flatMap { $0 > 0 ? $0 : nil } ?? Self.referenceBPM
        let speed = Float(tempo) / Float(Self.referenceBPM)
        let stateChanged = self.playing != playing
        let identityChanged = self.trackIdentity != trackIdentity
        let visibilityChanged = self.visible != visible
        let presentationChanged = stateChanged || identityChanged || visibilityChanged || rotationSpeed != speed
        let now = CACurrentMediaTime()
        let durationChanged = playbackClock.duration != duration
        let clockNeedsCorrection = playing && self.playing && position.map {
            abs($0 - playbackClock.position(at: now)) >= 0.2
        } == true
        let sampleChanged = durationChanged || playbackClock.samplePosition != position || clockNeedsCorrection
        guard presentationChanged || sampleChanged else { return }
        // Let the existing sweep continue when the sampled position agrees with its clock.
        // Compare against the last scheduled sweep so small corrections cannot accumulate.
        if !presentationChanged, playing, visible, cuePosition == nil, !durationChanged, !clockNeedsCorrection,
           let position, position >= 0, position < playbackClock.validDuration {
            return
        }
        let previousAngle = displayedNeedleAngle
        if sampleChanged || stateChanged || identityChanged {
            playbackClock.update(position: position, duration: duration, playing: playing,
                                 reset: identityChanged, at: now)
        }
        self.trackIdentity = trackIdentity
        self.playing = playing
        self.visible = visible
        rotationSpeed = speed
        if identityChanged { cueHoldPosition = nil }
        if visible {
            updateArtwork(animated: false)
        } else {
            setNeedleHovered(false)
            cover.removeAnimation(forKey: "artwork")
        }
        if stateChanged { updateNeedleControl() }
        updateAnimation(from: previousAngle, returning: identityChanged && previousAngle != nil)
    }

    private func needleContains(_ point: NSPoint) -> Bool {
        let center = pivot.position
        if hypot(point.x - center.x, point.y - center.y) <= Self.needleButtonRadius { return true }
        guard !isNeedleButtonDetached else { return false }
        let displayedArm = window == nil ? arm : (arm.presentation() ?? arm)
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
        if tonearmButton.frame != container.bounds { tonearmButton.frame = container.bounds }
        let center = isNeedleButtonDetached
            ? CGPoint(x: container.bounds.midX, y: container.bounds.midY) : arm.position
        if pivot.position != center {
            pivot.position = center
            pivotGlyph.position = center
        }
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
        pivot.fillColor = nil
        pivotMaterial.opacity = 1
        pivotGlyph.fillColor = NSColor(white: needleHovered ? 0.08 : 0.22, alpha: 1).cgColor
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

    @objc private func accessibilityAnimationChanged() { updateAnimation() }

    private func updateAnimation(from previousAngle: Double? = nil, returning: Bool = false) {
        let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        setRotationSpeed(playing && visible && cuePosition != false && !reducedMotion ? rotationSpeed : 0)
        synchronizeTonearm(from: previousAngle, returning: returning)
    }

    // Lift/park before pause and return to the saved groove before play.
    // Pending samples cannot override an explicit cue operation.
    func cueNeedle(ontoRecord: Bool) async {
        if !ontoRecord { cueHoldPosition = playbackClock.position(at: CACurrentMediaTime()) }
        else { cueHoldPosition = nil }
        cuePosition = ontoRecord
        guard visible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            updateAnimation()
            return
        }
        await withCheckedContinuation { continuation in
            CATransaction.begin()
            CATransaction.setCompletionBlock { continuation.resume() }
            updateAnimation()
            CATransaction.commit()
        }
    }

    func followPlayback() {
        cuePosition = nil
        cueHoldPosition = nil
        updateAnimation()
    }

    private var displayedNeedleAngle: Double? {
        (arm.presentation()?.value(forKeyPath: "transform.rotation.z") as? Double)
            ?? (arm.value(forKeyPath: "transform.rotation.z") as? Double)
    }

    private func synchronizeTonearm(from previousAngle: Double? = nil, returning: Bool = false) {
        guard let geometry else { return }
        let position = cueHoldPosition ?? playbackClock.position(at: CACurrentMediaTime())
        let progress = playbackClock.progress(for: position)
        let engaged = cuePosition ?? playing
        let angle = engaged ? geometry.angle(at: progress) : geometry.parkedAngle
        let previous = previousAngle ?? displayedNeedleAngle ?? angle
        let moving = playing && cuePosition != false && playbackClock.validDuration > 0
        let remaining = moving ? max(0, playbackClock.validDuration - position) : 0
        let animate = visible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let correction = animate && abs(previous - angle) > 0.001 ? (cuePosition != nil ? 0.28 : (returning ? 0.30 : 0.22)) : 0
        arm.removeAnimation(forKey: "needle")
        arm.removeAnimation(forKey: "grooveSweep")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let endAngle = animate && remaining > 0 ? geometry.endAngle : angle
        arm.setValue(endAngle, forKeyPath: "transform.rotation.z")
        if animate && remaining > 0 {
            // One server-side interpolation until the end of the song or a clock correction.
            let animation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            if correction > 0 {
                animation.values = [previous, angle, endAngle]
                animation.keyTimes = [0, NSNumber(value: correction / (remaining + correction)), 1]
                animation.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .linear)]
            } else {
                animation.values = [angle, endAngle]
                animation.keyTimes = [0, 1]
                animation.timingFunctions = [CAMediaTimingFunction(name: .linear)]
            }
            animation.duration = remaining + correction
            arm.add(animation, forKey: "grooveSweep")
        } else if correction > 0 {
            let animation = CABasicAnimation(keyPath: "transform.rotation.z")
            animation.fromValue = previous
            animation.toValue = angle
            animation.duration = correction
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            arm.add(animation, forKey: "needle")
        }
        CATransaction.commit()
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
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        guard bounds.size != laidOutSize || scale != laidOutScale || needsMaterialRefresh else {
            layoutNeedleButton()
            return
        }
        laidOutSize = bounds.size
        laidOutScale = scale
        let diameter = min(bounds.width - 28, (bounds.height - 26) / 1.08)
        guard diameter > 0 else { return }
        let deferMaterialRendering = isInLiveResize || window?.inLiveResize == true
        let center = CGPoint(x: bounds.midX, y: bounds.midY - diameter * 0.04)
        let diameterChanged = geometry?.diameter != diameter
        let geometry = VinylTonearmGeometry(diameter: diameter, center: center)
        self.geometry = geometry
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        recordShadow.position = center
        record.position = center
        let discFrame = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
        reflection.frame = discFrame
        rim.frame = discFrame
        arm.position = geometry.pivot
        let key = VinylMaterialCache.key(diameter: diameter, scale: scale)
        // Keep the previous bitmaps while dragging; Core Animation scales them
        // with the geometry. Render the exact pixels once live resize ends.
        if (!deferMaterialRendering || textureKey == nil),
           key != textureKey,
           let textures = VinylMaterialCache.textures(diameter: diameter, scale: scale) {
            textureKey = key
            surface.contents = textures.disc
            reflection.contents = textures.light
            surface.contentsScale = scale
            reflection.contentsScale = scale
        }
        if diameterChanged { layoutDiameter(diameter, armLength: geometry.armLength) }
        if (!deferMaterialRendering && (diameterChanged || scale != armMaterial.contentsScale || needsMaterialRefresh))
            || armMaterial.contents == nil {
            let metal = VinylMetalRenderer.render(diameter: diameter, armLength: geometry.armLength, scale: scale)
            armMaterial.contents = metal.arm
            armMaterial.contentsScale = scale
            pivotMaterial.contents = metal.pivot
            pivotMaterial.contentsScale = scale
        }
        layoutNeedleButton()
        CATransaction.commit()
        if !deferMaterialRendering { needsMaterialRefresh = false }
        if diameterChanged {
            // A different arm length changes the playable angular limits.
            synchronizeTonearm(from: geometry.angle(at: playbackClock.progress(for: cueHoldPosition ?? playbackClock.position(at: CACurrentMediaTime()))))
        }
    }

    private func layoutDiameter(_ diameter: CGFloat, armLength length: CGFloat) {
        record.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        recordShadow.bounds = record.bounds
        recordShadow.shadowPath = CGPath(ellipseIn: recordShadow.bounds, transform: nil)
        surface.frame = record.bounds
        let coverInset = diameter * 0.245
        cover.frame = record.bounds.insetBy(dx: coverInset, dy: coverInset)
        cover.cornerRadius = cover.bounds.width / 2
        labelRing.path = CGPath(ellipseIn: cover.frame.insetBy(dx: -1.3, dy: -1.3), transform: nil)
        spindle.path = CGPath(ellipseIn: CGRect(x: diameter / 2 - 2.1, y: diameter / 2 - 2.1, width: 4.2, height: 4.2), transform: nil)
        rim.path = CGPath(ellipseIn: rim.bounds.insetBy(dx: 0.5, dy: 0.5), transform: nil)
        arm.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        // Unrotated arm points down. Its exact endpoint is the stylus contact;
        // circle intersection determines both playable angular limits.
        let needle = CGMutablePath()
        needle.move(to: CGPoint(x: 0, y: diameter * 0.055))
        needle.addLine(to: CGPoint(x: 0, y: -length * 0.70))
        needle.addCurve(to: CGPoint(x: 0, y: -length),
                        control1: CGPoint(x: diameter * 0.036, y: -length * 0.82),
                        control2: CGPoint(x: diameter * 0.026, y: -length * 0.94))
        arm.path = needle
        arm.lineWidth = min(6, max(2.8, diameter * 0.017))
        armMaterial.frame = VinylMetalRenderer.armBounds(diameter: diameter, armLength: length)
        arm.shadowPath = needle.copy(strokingWithWidth: arm.lineWidth, lineCap: .round, lineJoin: .round, miterLimit: 1)
        armHitPath = needle.copy(strokingWithWidth: 24, lineCap: .round, lineJoin: .round, miterLimit: 1)
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

/// Circle-circle intersection: the stylus stays in the playable annulus for
/// every interpolated angle, independent of the component's display size.
struct VinylTonearmGeometry {
    let diameter: CGFloat
    let center: CGPoint
    let pivot: CGPoint
    let armLength: CGFloat
    let outerRadius: CGFloat
    let innerRadius: CGFloat
    let startAngle: Double
    let endAngle: Double

    init(diameter: CGFloat, center: CGPoint) {
        self.diameter = diameter
        self.center = center
        pivot = CGPoint(x: center.x + diameter * 0.47, y: center.y + diameter * 0.43)
        armLength = diameter * 0.65
        outerRadius = diameter * 0.455
        innerRadius = diameter * 0.315
        let dx = center.x - pivot.x
        let dy = center.y - pivot.y
        let distance = hypot(dx, dy)
        let bearing = atan2(dy, dx)
        let length = armLength
        func intersectionAngle(radius: CGFloat) -> Double {
            let cosine = (distance * distance + length * length - radius * radius) / (2 * distance * length)
            return Double(bearing + acos(min(1, max(-1, cosine))) + .pi / 2)
        }
        startAngle = intersectionAngle(radius: outerRadius)
        endAngle = intersectionAngle(radius: innerRadius)
    }

    var parkedAngle: Double { startAngle + 0.16 }

    func angle(at progress: Double) -> Double {
        let fraction = progress.isFinite ? min(1, max(0, progress)) : 0
        return startAngle + (endAngle - startAngle) * fraction
    }

    func contact(at progress: Double) -> CGPoint {
        let angle = angle(at: progress)
        return CGPoint(x: pivot.x + armLength * sin(angle), y: pivot.y - armLength * cos(angle))
    }
}

/// Authoritative samples arrive through PlaybackMonitor; interpolation uses the
/// same monotonic media clock as the lyrics. No additional Music polling.
struct VinylPlaybackClock {
    private(set) var samplePosition: TimeInterval?
    private(set) var duration: TimeInterval?
    private var basePosition: TimeInterval = 0
    private var sampledAt: CFTimeInterval = 0
    private var playing = false

    var validDuration: TimeInterval {
        guard let duration, duration.isFinite, duration > 0 else { return 0 }
        return duration
    }

    mutating func update(position: TimeInterval?, duration: TimeInterval?, playing: Bool,
                         reset: Bool, at now: CFTimeInterval) {
        let estimated = self.position(at: now)
        samplePosition = position
        self.duration = duration
        basePosition = position.flatMap { $0.isFinite ? max(0, $0) : nil } ?? (reset ? 0 : estimated)
        sampledAt = now
        self.playing = playing
    }

    func position(at now: CFTimeInterval) -> TimeInterval {
        let position = basePosition + (playing ? max(0, now - sampledAt) : 0)
        return validDuration > 0 ? min(validDuration, position) : position
    }

    func progress(for position: TimeInterval) -> Double {
        guard validDuration > 0, position.isFinite else { return 0 }
        return min(1, max(0, position / validDuration))
    }
}

private final class VinylMaterials {
    let disc: CGImage
    let light: CGImage
    init(disc: CGImage, light: CGImage) { self.disc = disc; self.light = light }
}

private enum VinylMaterialCache {
    private static let cache: NSCache<NSString, VinylMaterials> = {
        let cache = NSCache<NSString, VinylMaterials>()
        cache.totalCostLimit = 16 * 1024 * 1024
        cache.countLimit = 8
        return cache
    }()

    static func key(diameter: CGFloat, scale: CGFloat) -> String { "\(diameter)@\(scale)" }

    static func textures(diameter: CGFloat, scale: CGFloat) -> VinylMaterials? {
        let pixels = Int(ceil(diameter * scale))
        guard pixels > 0, pixels <= 4096 else { return nil }
        let key = key(diameter: diameter, scale: scale) as NSString
        if let cached = cache.object(forKey: key) { return cached }
        func context() -> CGContext? {
            CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                      bytesPerRow: pixels * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        guard let disc = context(), let light = context() else { return nil }
        for ctx in [disc, light] { ctx.scaleBy(x: scale, y: scale) }
        let bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        let center = CGPoint(x: diameter / 2, y: diameter / 2)
        let radius = diameter / 2 - 0.5
        disc.addEllipse(in: bounds.insetBy(dx: 0.5, dy: 0.5))
        disc.clip()
        let colors = [CGColor(gray: 0.055, alpha: 1), CGColor(gray: 0.105, alpha: 1), CGColor(gray: 0.045, alpha: 1)]
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors as CFArray, locations: [0, 0.64, 1]) {
            disc.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                                    endCenter: center, endRadius: radius, options: .drawsAfterEndLocation)
        }
        // Screen-space spacing stays above the pixel Nyquist limit. Small
        // deterministic variations avoid a coarse, uniformly striped pattern.
        let spacing = max(1.5, 3.0 / scale)
        let grooveLineWidth = max(0.32, 0.75 / scale)
        var grooveRadius = diameter * 0.277
        var index = 0
        let darkGrooves = CGMutablePath()
        disc.setLineWidth(grooveLineWidth)
        while grooveRadius < diameter * 0.476 {
            let variation = sin(Double(index) * 2.39996)
            disc.setStrokeColor(CGColor(gray: 0.54, alpha: 0.025 + 0.018 * (variation + 1)))
            let ring = CGRect(x: center.x - grooveRadius, y: center.y - grooveRadius,
                              width: grooveRadius * 2, height: grooveRadius * 2)
            disc.strokeEllipse(in: ring)
            darkGrooves.addEllipse(in: ring.insetBy(dx: 0.42, dy: 0.42))
            grooveRadius += spacing * (1 + CGFloat(variation) * 0.055)
            index += 1
        }
        disc.setStrokeColor(CGColor(gray: 0, alpha: 0.14))
        disc.addPath(darkGrooves)
        disc.strokePath()
        // Lead-in / run-out and a beveled edge, all baked into one bitmap.
        for (fraction, brightness, alpha) in [(0.492, 0.6, 0.25), (0.485, 0.0, 0.7), (0.271, 0.55, 0.20), (0.263, 0.0, 0.65)] {
            let r = diameter * fraction
            disc.setStrokeColor(CGColor(gray: brightness, alpha: alpha))
            disc.setLineWidth(0.7)
            disc.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
        }
        // Smooth directional reflection, independent of disc rotation. Raster
        // once per display size; no live blur, shader or animated mask.
        guard let data = light.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let centerPixel = Double(pixels) / 2
        let density = Double(scale)
        let diameterInPoints = Double(diameter)
        let grooveFrequency = 2 * Double.pi / Double(spacing)
        // Keep a pixel of slack on both edges. The original point-space
        // radius test still decides every pixel at the boundary.
        let outerRadius = diameterInPoints * 0.497 * density + 1
        let innerRadius = max(0, diameterInPoints * 0.261 * density - 1)
        let centerColumn = centerPixel - 0.5
        let firstColumn = pixels / 2
        let columns = (firstColumn..<pixels).map { (Double($0) + 0.5 - centerPixel) / density }
        // Mirrored pixels have the same distance and radial shading. Compute
        // those once per group while keeping each pixel's directional lobes.
        for y in 0..<((pixels + 1) / 2) {
            let pixelY = centerPixel - Double(y) - 0.5
            let ySquared = pixelY * pixelY
            let outerSquared = outerRadius * outerRadius - ySquared
            guard outerSquared >= 0 else { continue }
            let upper = min(pixels, Int(floor(centerColumn + sqrt(outerSquared))) + 1)
            let innerSquared = innerRadius * innerRadius - ySquared
            let lower = innerSquared > 0
                ? max(firstColumn, Int(floor(centerColumn + sqrt(innerSquared))) + 1)
                : firstColumn
            guard lower < upper else { continue }
            let dy = pixelY / density
            let mirrorY = pixels - 1 - y
            for x in lower..<upper {
                let dx = columns[x - firstColumn]
                let distance = hypot(dx, dy)
                let r = distance / diameterInPoints
                guard r > 0.261, r < 0.497 else { continue }
                let edge = min(1, (r - 0.261) / 0.018) * min(1, (0.497 - r) / 0.012)
                let bandDistance = (r - 0.405) / 0.09
                let band = 0.72 + 0.28 * exp(-bandDistance * bandDistance)
                let grooves = 0.93 + 0.07 * cos(distance * grooveFrequency)
                let radial = edge * band * grooves
                // Derive mirrored quadrant angles from the first quadrant instead of repeating atan2.
                let theta0 = atan2(dy, dx)
                func drawPixel(x: Int, y: Int, theta: Double) {
                    func lobe(_ direction: Double, _ width: Double) -> Double {
                        var delta = theta - direction
                        if delta > .pi { delta -= 2 * .pi }
                        else if delta < -.pi { delta += 2 * .pi }
                        delta /= width
                        return exp(-0.5 * delta * delta)
                    }
                    let alpha = min(0.48, (0.44 * lobe(2.28, 0.35) + 0.21 * lobe(-0.86, 0.40)) * radial)
                    let offset = (y * pixels + x) * 4
                    data[offset] = UInt8(192 * alpha)
                    data[offset + 1] = UInt8(202 * alpha)
                    data[offset + 2] = UInt8(211 * alpha)
                    data[offset + 3] = UInt8(255 * alpha)
                }
                let mirrorX = pixels - 1 - x
                drawPixel(x: x, y: y, theta: theta0)
                if mirrorX != x { drawPixel(x: mirrorX, y: y, theta: .pi - theta0) }
                if mirrorY != y {
                    drawPixel(x: x, y: mirrorY, theta: -theta0)
                    if mirrorX != x { drawPixel(x: mirrorX, y: mirrorY, theta: theta0 - .pi) }
                }
            }
        }
        guard let discImage = disc.makeImage(), let lightImage = light.makeImage() else { return nil }
        let result = VinylMaterials(disc: discImage, light: lightImage)
        cache.setObject(result, forKey: key, cost: pixels * pixels * 8)
        return result
    }
}

/// Size-dependent mechanical artwork. The renderer runs only on geometry/scale
/// changes; the resulting narrow bitmap moves rigidly around the fixed bearing.
enum VinylMetalRenderer {
    struct Result {
        let arm: CGImage?
        let pivot: CGImage?
        let armBounds: CGRect
    }

    private final class CachedArtwork {
        let result: Result
        init(_ result: Result) { self.result = result }
    }

    private static let cache: NSCache<NSString, CachedArtwork> = {
        let cache = NSCache<NSString, CachedArtwork>()
        cache.countLimit = 16
        cache.totalCostLimit = 4 * 1024 * 1024
        return cache
    }()

    static func armBounds(diameter: CGFloat, armLength: CGFloat) -> CGRect {
        let halfWidth = max(16, diameter * 0.048 + 6)
        return CGRect(x: -halfWidth, y: -armLength - 5, width: 2 * halfWidth, height: armLength + 25)
    }

    static func render(diameter: CGFloat, armLength: CGFloat, scale: CGFloat) -> Result {
        // Exact geometry keys preserve subpixel alignment and mechanical proportions.
        // Cache ownership is bounded; image layers retain any artwork still in use.
        let key = "\(diameter):\(armLength):\(scale)" as NSString
        if let cached = cache.object(forKey: key) { return cached.result }
        let tubeWidth = min(6, max(3.4, diameter * 0.019))
        let headWidth = min(12, max(7, diameter * 0.047))
        let headHeight = min(18, max(10, diameter * 0.073))
        let armBounds = Self.armBounds(diameter: diameter, armLength: armLength)
        func context(_ bounds: CGRect) -> CGContext? {
            guard let ctx = CGContext(data: nil, width: Int(ceil(bounds.width * scale)), height: Int(ceil(bounds.height * scale)),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
            return ctx
        }
        func gradient(_ ctx: CGContext, path: CGPath, grays: [CGFloat], start: CGPoint, end: CGPoint) {
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            let colors = grays.map { CGColor(red: $0 * 0.96, green: $0 * 0.985, blue: $0, alpha: 1) }
            if let fill = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: nil) {
                ctx.drawLinearGradient(fill, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
            ctx.restoreGState()
        }
        let ctx = context(armBounds)
        if let ctx {
            let p0 = CGPoint(x: 0, y: -armLength * 0.68)
            let p1 = CGPoint(x: diameter * 0.035, y: -armLength * 0.80)
            let p2 = CGPoint(x: diameter * 0.030, y: -armLength * 0.91)
            let p3 = CGPoint(x: 0, y: -armLength + headHeight * 0.62)
            var points = [CGPoint(x: 0, y: 14), CGPoint(x: 0, y: 0), p0]
            for index in 1...36 {
                let t = CGFloat(index) / 36
                let u = 1 - t
                points.append(CGPoint(x: u*u*u*p0.x + 3*u*u*t*p1.x + 3*u*t*t*p2.x + t*t*t*p3.x,
                                      y: u*u*u*p0.y + 3*u*u*t*p1.y + 3*u*t*t*p2.y + t*t*t*p3.y))
            }
            let normals = points.indices.map { index -> CGPoint in
                let before = points[max(0, index - 1)]
                let after = points[min(points.count - 1, index + 1)]
                let length = max(0.001, hypot(after.x - before.x, after.y - before.y))
                return CGPoint(x: -(after.y - before.y) / length, y: (after.x - before.x) / length)
            }
            func edge(_ offset: CGFloat) -> [CGPoint] {
                zip(points, normals).map { CGPoint(x: $0.x + $1.x * offset, y: $0.y + $1.y * offset) }
            }
            // Cross-section bands follow the bent tube's normals, forming a
            // cylinder rather than constant-offset white lines on a flat stroke.
            ctx.saveGState()
            let outline = CGMutablePath()
            outline.addLines(between: edge(-tubeWidth / 2))
            for point in edge(tubeWidth / 2).reversed() { outline.addLine(to: point) }
            outline.closeSubpath()
            ctx.addPath(outline)
            ctx.clip()
            ctx.setShouldAntialias(false)
            for band in 0..<20 {
                let fraction = Double(band) / 19
                let gray = 0.34 + 0.52 * exp(-pow((fraction - 0.28) / 0.22, 2))
                    + 0.13 * exp(-pow((fraction - 0.72) / 0.19, 2))
                let left = edge(tubeWidth * (CGFloat(band) / 20 - 0.5))
                let right = edge(tubeWidth * (CGFloat(band + 1) / 20 - 0.5) + 0.02)
                let path = CGMutablePath()
                path.addLines(between: left)
                for point in right.reversed() { path.addLine(to: point) }
                path.closeSubpath()
                ctx.setFillColor(CGColor(red: gray * 0.96, green: gray * 0.985, blue: gray, alpha: 1))
                ctx.addPath(path)
                ctx.fillPath()
            }
            ctx.restoreGState()
            // Restrained longitudinal machining, entirely baked into the bitmap.
            for offset in [-0.30, -0.12, 0.18, 0.34] {
                ctx.setStrokeColor(CGColor(gray: 0.92, alpha: 0.10))
                ctx.setLineWidth(0.10)
                ctx.addLines(between: edge(tubeWidth * offset))
                ctx.strokePath()
            }
            let weight = CGRect(x: -tubeWidth * 1.3, y: 5, width: tubeWidth * 2.6, height: 10)
            let weightPath = CGPath(roundedRect: weight, cornerWidth: 2, cornerHeight: 2, transform: nil)
            gradient(ctx, path: weightPath, grays: [0.13, 0.39, 0.22, 0.10],
                     start: CGPoint(x: weight.minX, y: 0), end: CGPoint(x: weight.maxX, y: 0))
            ctx.setStrokeColor(CGColor(gray: 0.65, alpha: 0.38))
            ctx.setLineWidth(0.45)
            ctx.move(to: CGPoint(x: weight.minX + 1, y: weight.minY + 1.5))
            ctx.addLine(to: CGPoint(x: weight.maxX - 1, y: weight.minY + 1.5))
            ctx.strokePath()
            // Contact shadow sits directly under the stylus, not an oversized halo.
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.24))
            ctx.fillEllipse(in: CGRect(x: -1.7, y: -armLength - 0.9, width: 4, height: 1.8))
            let head = CGRect(x: -headWidth / 2, y: -armLength + 2.4, width: headWidth, height: headHeight)
            let shell = CGMutablePath()
            shell.addLines(between: [CGPoint(x: head.minX + 1, y: head.maxY), CGPoint(x: head.maxX - 1, y: head.maxY),
                                    CGPoint(x: head.maxX, y: head.maxY - 2), CGPoint(x: head.maxX - 0.7, y: head.minY),
                                    CGPoint(x: head.minX + 0.7, y: head.minY), CGPoint(x: head.minX, y: head.maxY - 2)])
            shell.closeSubpath()
            gradient(ctx, path: shell, grays: [0.40, 0.23, 0.12, 0.18],
                     start: CGPoint(x: head.minX, y: 0), end: CGPoint(x: head.maxX, y: 0))
            ctx.setStrokeColor(CGColor(gray: 0.74, alpha: 0.48))
            ctx.setLineWidth(0.5)
            ctx.move(to: CGPoint(x: head.minX + 1, y: head.minY + 1))
            ctx.addLine(to: CGPoint(x: head.minX + 1, y: head.maxY - 2))
            ctx.addLine(to: CGPoint(x: head.maxX - 1, y: head.maxY - 2))
            ctx.strokePath()
            // The connector collar and front cartridge stay attached to the tube.
            ctx.setFillColor(CGColor(gray: 0.63, alpha: 1))
            ctx.fill(CGRect(x: -tubeWidth * 0.62, y: head.maxY - 1.5, width: tubeWidth * 1.24, height: 1.4))
            ctx.setFillColor(CGColor(gray: 0.095, alpha: 1))
            ctx.fill(CGRect(x: head.minX + 1, y: head.minY + 1.2, width: head.width - 2, height: 2.8))
            ctx.setStrokeColor(CGColor(red: 0.68, green: 0.64, blue: 0.52, alpha: 1))
            ctx.setLineWidth(0.8)
            ctx.move(to: CGPoint(x: 0, y: head.minY + 1))
            ctx.addLine(to: CGPoint(x: 0, y: -armLength))
            ctx.strokePath()
            if diameter >= 180 {
                ctx.setFillColor(CGColor(gray: 0.72, alpha: 0.85))
                for x in [-head.width * 0.24, head.width * 0.24] {
                    ctx.fillEllipse(in: CGRect(x: x - 0.5, y: head.maxY - 4.2, width: 1, height: 1))
                }
            }
        }
        let hub = context(CGRect(x: -11, y: -11, width: 22, height: 22))
        if let hub {
            // Outer bearing housing, recessed race, and axle cap serve distinct
            // mechanical roles. All share the same upper-left light direction.
            func circle(_ radius: CGFloat) -> CGPath {
                CGPath(ellipseIn: CGRect(x: -radius, y: -radius, width: 2*radius, height: 2*radius), transform: nil)
            }
            gradient(hub, path: circle(11), grays: [0.82, 0.49, 0.19],
                     start: CGPoint(x: -9, y: 9), end: CGPoint(x: 10, y: -10))
            hub.setFillColor(CGColor(gray: 0.10, alpha: 1))
            hub.addPath(circle(8.8)); hub.fillPath()
            gradient(hub, path: circle(7.9), grays: [0.29, 0.52, 0.15],
                     start: CGPoint(x: -6, y: 7), end: CGPoint(x: 8, y: -8))
            hub.setFillColor(CGColor(gray: 0.11, alpha: 1))
            hub.addPath(circle(6.4)); hub.fillPath()
            gradient(hub, path: circle(5.9), grays: [0.78, 0.59, 0.36],
                     start: CGPoint(x: -5, y: 5), end: CGPoint(x: 5, y: -5))
        }
        let result = Result(arm: ctx?.makeImage(), pivot: hub?.makeImage(), armBounds: armBounds)
        if let arm = result.arm, let pivot = result.pivot {
            cache.setObject(CachedArtwork(result), forKey: key,
                            cost: arm.bytesPerRow * arm.height + pivot.bytesPerRow * pivot.height)
        }
        return result
    }
}
