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
    private let pivot = CAShapeLayer()
    private var playing = false
    private var visible = false
    private var armEngaged = false

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
        arm.strokeColor = NSColor.white.cgColor
        arm.lineCap = .round
        arm.lineJoin = .round
        arm.anchorPoint = .zero
        arm.setValue(0.20, forKeyPath: "transform.rotation.z")
        arm.shadowColor = NSColor.black.cgColor
        arm.shadowOpacity = 0.32
        arm.shadowRadius = 2
        arm.shadowOffset = CGSize(width: 0, height: -1)
        layer?.addSublayer(arm)
        pivot.fillColor = NSColor.white.cgColor
        pivot.strokeColor = NSColor.black.withAlphaComponent(0.12).cgColor
        pivot.lineWidth = 3
        layer?.addSublayer(pivot)
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
        setAccessibilityRole(.image)
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
        self.playing = playing
        self.visible = visible
        updateAnimation()
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
        needle.addLine(to: CGPoint(x: diameter * 0.48, y: -diameter * 0.28))
        arm.path = needle
        arm.lineWidth = max(3, diameter * 0.019)
        pivot.path = CGPath(ellipseIn: CGRect(x: pivotPoint.x - 6, y: pivotPoint.y - 6, width: 12, height: 12), transform: nil)
        CATransaction.commit()
    }
}
