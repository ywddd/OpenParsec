import UIKit

final class VirtualMouseOverlay: UIView {
	var configuration = VirtualMouseConfiguration(
		enabled: true,
		scale: VirtualMouseConfiguration.defaultScale,
		normalizedPosition: VirtualMouseConfiguration.defaultPosition
	) {
		didSet { setNeedsLayout() }
	}

	var usableRect: CGRect = .zero {
		didSet { setNeedsLayout() }
	}

	var safeInsets = VirtualMouseInsets.zero {
		didSet { setNeedsLayout() }
	}

	var onMove: ((CGPoint) -> Void)?
	var onButton: ((VirtualMouseButton, Bool) -> Void)?
	var onScroll: ((Int32) -> Void)?
	var onPositionChanged: ((CGPoint) -> Void)?
	var onScaleChanged: ((CGFloat) -> Void)?
	var onCollapsedChanged: ((Bool) -> Void)?

	private(set) var presentation: VirtualMousePresentation?
	private(set) var isCollapsed = false
	private var localPresentation: VirtualMousePresentation?

	private struct TouchState {
		let interaction: VirtualMouseInteraction
		let startPoint: CGPoint
		var lastPoint: CGPoint
		var wheelRemainder: CGFloat = 0
		var startScale: CGFloat = 1
	}

	private var activeTouches: [UITouch: TouchState] = [:]
	private let bodyView = VirtualMouseBodyView()
	private var reducer = VirtualMouseButtonReducer()

	override init(frame: CGRect) {
		super.init(frame: frame)
		backgroundColor = .clear
		isMultipleTouchEnabled = true
		autoresizingMask = []
		bodyView.isUserInteractionEnabled = false
		addSubview(bodyView)
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func layoutSubviews() {
		super.layoutSubviews()
		frame = superview?.bounds ?? bounds
		let rect = usableRect.width > 0 && usableRect.height > 0
			? usableRect
			: CGRect(origin: .zero, size: superview?.bounds.size ?? bounds.size)
		let next = VirtualMouseGeometry.presentation(
			configuration: configuration,
			in: rect,
			insets: safeInsets,
			collapsed: isCollapsed
		)
		if next.isCollapsed != isCollapsed {
			releaseAll()
			isCollapsed = next.isCollapsed
		}
		presentation = next
		localPresentation = next.localizedToBody
		bodyView.frame = next.bodyFrame
		bodyView.presentation = localPresentation
		bodyView.setNeedsDisplay()
	}

	func setSuspended(_ suspended: Bool) {
		if isHidden == suspended { return }
		if suspended { releaseAll() }
		isHidden = suspended
	}

	func setCollapsed(_ collapsed: Bool) {
		if isCollapsed == collapsed { return }
		releaseAll()
		isCollapsed = collapsed
		onCollapsedChanged?(collapsed)
		setNeedsLayout()
	}

	func releaseAll() {
		for button in reducer.cancelAll().released {
			onButton?(button, false)
		}
		activeTouches.removeAll()
		bodyView.setNeedsDisplay()
	}

	override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
		guard !isHidden, let presentation = presentation else { return false }
		return presentation.bodyFrame.insetBy(dx: -8, dy: -8).contains(point)
	}

	override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
		guard let presentation = presentation, let localPresentation = localPresentation else { return }
		if presentation.isCollapsed {
			if touches.contains(where: { point(inside: $0.location(in: self), with: event) }) {
				setCollapsed(false)
			}
			return
		}
		guard let layout = localPresentation.layout else { return }
		var shouldCollapse = false
		for touch in touches {
			let bodyPoint = touch.location(in: bodyView)
			guard bodyView.bounds.contains(bodyPoint),
				  let interaction = VirtualMouseGeometry.interaction(at: bodyPoint, layout: layout),
				  activeTouches[touch] == nil else { continue }
			if case .button(let button) = interaction, isButtonHeld(button) { continue }
			activeTouches[touch] = TouchState(
				interaction: interaction,
				startPoint: touch.location(in: self),
				lastPoint: touch.location(in: self),
				startScale: presentation.scale
			)
			if case .button(let button) = interaction {
				for pressed in reducer.down(button).pressed { onButton?(pressed, true) }
			} else if case .collapse = interaction {
				shouldCollapse = true
			}
		}
		if shouldCollapse { setCollapsed(true) }
	}

	override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
		for touch in touches {
			guard var state = activeTouches[touch] else { continue }
			let point = touch.location(in: self)
			let delta = CGPoint(x: point.x - state.lastPoint.x,
								y: point.y - state.lastPoint.y)
			switch state.interaction {
			case .button, .move:
				if delta != .zero { onMove?(delta) }
			case .wheel:
				state.wheelRemainder += delta.y / 8
				let units = Int32(state.wheelRemainder)
				if units != 0 {
					state.wheelRemainder -= CGFloat(units)
					onScroll?(units)
				}
			case .reposition:
				let next = CGPoint(x: configuration.normalizedPosition.x
								  + delta.x / max(1, usableRect.width - safeInsets.left - safeInsets.right),
								   y: configuration.normalizedPosition.y
								  + delta.y / max(1, usableRect.height - safeInsets.top - safeInsets.bottom))
				configuration.normalizedPosition =
					VirtualMouseGeometry.normalizedPosition(next)
				onPositionChanged?(configuration.normalizedPosition)
				setNeedsLayout()
			case .resize:
				let scale = VirtualMouseConfiguration.clampedScale(
					state.startScale - (point.y - state.startPoint.y) / 120
				)
				configuration.scale = scale
				onScaleChanged?(scale)
				setNeedsLayout()
			case .collapse:
				break
			}
			state.lastPoint = point
			activeTouches[touch] = state
		}
	}

	override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
		finishTouches(touches)
	}

	override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
		finishTouches(touches)
	}

	private func isButtonHeld(_ button: VirtualMouseButton) -> Bool {
		activeTouches.values.contains { state in
			if case .button(let held) = state.interaction { return held == button }
			return false
		}
	}

	private func finishTouches(_ touches: Set<UITouch>) {
		for touch in touches {
			guard let state = activeTouches.removeValue(forKey: touch) else { continue }
			if case .button(let button) = state.interaction {
				for released in reducer.up(button).released { onButton?(released, false) }
			}
		}
		bodyView.setNeedsDisplay()
	}

	override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
		guard !isHidden, let presentation = presentation else { return nil }
		return presentation.bodyFrame.insetBy(dx: -8, dy: -8).contains(point) ? self : nil
	}
}

private final class VirtualMouseBodyView: UIView {
	var presentation: VirtualMousePresentation? {
		didSet { setNeedsDisplay() }
	}

	override func draw(_ rect: CGRect) {
		guard let presentation = presentation else { return }
		if presentation.isCollapsed {
			drawCollapsed(in: rect)
			return
		}
		guard let layout = presentation.layout else { return }
		let bodyPath = UIBezierPath(roundedRect: bounds, cornerRadius: 30)
		UIColor(white: 0.14, alpha: 0.88).setFill()
		bodyPath.fill()
		UIColor.white.withAlphaComponent(0.2).setStroke()
		bodyPath.lineWidth = 1
		bodyPath.stroke()
		drawControl(layout.repositionHandleFrame,
					fill: UIColor.white.withAlphaComponent(0.1))
		drawControl(layout.collapseButtonFrame,
					fill: UIColor.black.withAlphaComponent(0.3))
		drawGlyph("arrow.up.and.down.and.arrow.left.and.right",
				  in: layout.repositionHandleFrame, color: .white)
		drawGlyph("xmark", in: layout.collapseButtonFrame, color: .white)
		drawControl(layout.leftButtonFrame,
					fill: UIColor.white.withAlphaComponent(0.18))
		drawControl(layout.rightButtonFrame,
					fill: UIColor.white.withAlphaComponent(0.18))
		drawControl(layout.middleButtonFrame,
					fill: UIColor.white.withAlphaComponent(0.18))
		drawText("左", in: layout.leftButtonFrame)
		drawText("右", in: layout.rightButtonFrame)
		drawText("中", in: layout.middleButtonFrame)
		drawControl(layout.wheelFrame,
					fill: UIColor.white.withAlphaComponent(0.22))
		drawGlyph("arrow.up.and.down", in: layout.wheelFrame, color: .white)
		drawControl(layout.moveFrame,
					fill: UIColor.white.withAlphaComponent(0.07))
		drawGlyph("arrow.up.and.down.and.arrow.left.and.right",
				  in: layout.moveFrame, color: UIColor.white.withAlphaComponent(0.45))
		drawGlyph("arrow.up.left.and.arrow.down.right",
				  in: layout.resizeHandleFrame, color: UIColor.white.withAlphaComponent(0.65))
	}

	private func drawControl(_ frame: CGRect, fill: UIColor) {
		let path = UIBezierPath(roundedRect: frame, cornerRadius: 10)
		fill.setFill()
		path.fill()
	}

	private func drawCollapsed(in rect: CGRect) {
		let path = UIBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 22)
		UIColor(white: 0.2, alpha: 0.88).setFill()
		path.fill()
		UIColor.white.withAlphaComponent(0.25).setStroke()
		path.lineWidth = 1
		path.stroke()
		VirtualMouseDrawing.glyph("computermouse.fill", in: rect, color: .white)
	}

	private func drawText(_ text: String, in frame: CGRect) {
		let paragraph = NSMutableParagraphStyle()
		paragraph.alignment = .center
		let attributes: [NSAttributedString.Key: Any] = [
			.font: UIFont.systemFont(ofSize: 16, weight: .medium),
			.foregroundColor: UIColor.white,
			.paragraphStyle: paragraph
		]
		let height: CGFloat = 22
		text.draw(in: CGRect(x: frame.minX, y: frame.midY - height / 2,
							 width: frame.width, height: height),
				  withAttributes: attributes)
	}

	private func drawGlyph(_ name: String, in frame: CGRect, color: UIColor) {
		VirtualMouseDrawing.glyph(name, in: frame, color: color)
	}
}

private enum VirtualMouseDrawing {
	static func glyph(_ name: String, in frame: CGRect, color: UIColor) {
		guard let image = UIImage(systemName: name)?.withTintColor(color, renderingMode: .alwaysOriginal)
		else { return }
		let size = CGSize(width: min(24, frame.width - 10),
						  height: min(24, frame.height - 10))
		image.draw(in: CGRect(x: frame.midX - size.width / 2,
							  y: frame.midY - size.height / 2,
							  width: size.width, height: size.height))
	}
}
