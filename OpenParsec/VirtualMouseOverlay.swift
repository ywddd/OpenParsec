import UIKit

final class VirtualMouseOverlay: UIView {
	var configuration = VirtualMouseConfiguration(
		enabled: true,
		scale: VirtualMouseConfiguration.defaultScale,
		normalizedPosition: VirtualMouseConfiguration.defaultPosition
	) {
		didSet {
			if configuration.enabled != oldValue.enabled || configuration.scale != oldValue.scale {
				releaseAll()
			}
			setNeedsLayout()
		}
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
		var lastPoint: CGPoint
		var drag: VirtualMouseLauncherDrag
		var wheelRemainder: CGFloat = 0
	}

	private var activeTouches: [UITouch: TouchState] = [:]
	private let bodyView = VirtualMouseBodyView()
	private var reducer = VirtualMouseButtonReducer()

	override init(frame: CGRect) {
		super.init(frame: frame)
		isOpaque = false
		backgroundColor = .clear
		isMultipleTouchEnabled = true
		autoresizingMask = []
		bodyView.isUserInteractionEnabled = false
		isAccessibilityElement = false
		addSubview(bodyView)
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func layoutSubviews() {
		super.layoutSubviews()
		frame = superview?.bounds ?? bounds
		let next = VirtualMouseGeometry.presentation(
			configuration: configuration,
			in: effectiveUsableRect,
			insets: safeInsets,
			collapsed: isCollapsed
		)
		if next.isCollapsed != presentation?.isCollapsed {
			releaseAll()
		}
		presentation = next
		localPresentation = next.localizedToBody
		bodyView.frame = next.bodyFrame
		bodyView.presentation = localPresentation
		updateAccessibility()
	}

	func setSuspended(_ suspended: Bool) {
		if suspended { releaseAll() }
		if isHidden == suspended { return }
		isHidden = suspended
	}

	func setCollapsed(_ collapsed: Bool) {
		if isCollapsed == collapsed { return }
		releaseAll()
		isCollapsed = collapsed
		onCollapsedChanged?(collapsed)
		if let previous = presentation {
			let next = VirtualMouseGeometry.presentation(
				configuration: configuration, in: effectiveUsableRect, insets: safeInsets, collapsed: collapsed
			)
			let delta = CGPoint(x: previous.bodyFrame.minX - next.bodyFrame.minX,
								y: previous.bodyFrame.minY - next.bodyFrame.minY)
			let position = VirtualMouseGeometry.movedPosition(
				for: next.bodyFrame, by: delta, in: effectiveUsableRect, insets: safeInsets
			)
			if position != configuration.normalizedPosition {
				configuration.normalizedPosition = position
				onPositionChanged?(position)
			}
			if !collapsed && configuration.scale != next.scale {
				configuration.scale = next.scale
				onScaleChanged?(next.scale)
			}
		}
		setNeedsLayout()
	}

	func releaseAll() {
		for button in reducer.cancelAll().released {
			onButton?(button, false)
		}
		activeTouches.removeAll()
		bodyView.heldButtons = reducer.held
	}

	override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
		guard !isHidden, configuration.enabled, isUserInteractionEnabled, alpha > 0.01,
			  let localPresentation = localPresentation else { return false }
		return VirtualMouseGeometry.contains(convert(point, to: bodyView), in: localPresentation)
	}

	override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
		guard !isHidden, configuration.enabled else { return }
		guard let presentation = presentation, let localPresentation = localPresentation else { return }
		if presentation.isCollapsed {
			guard activeTouches.isEmpty,
				  let touch = touches.first(where: { point(inside: $0.location(in: self), with: event) }) else { return }
			let point = touch.location(in: self)
			activeTouches[touch] = TouchState(interaction: .reposition, lastPoint: point,
											 drag: VirtualMouseLauncherDrag(startPoint: point))
			return
		}
		guard let layout = localPresentation.layout else { return }
		for touch in touches {
			let bodyPoint = touch.location(in: bodyView)
			guard bodyView.bounds.contains(bodyPoint),
				  let interaction = VirtualMouseGeometry.interaction(at: bodyPoint, layout: layout),
				  activeTouches[touch] == nil else { continue }
			if case .button(let button) = interaction, isButtonHeld(button) { continue }
			let point = touch.location(in: self)
			activeTouches[touch] = TouchState(
				interaction: interaction,
				lastPoint: point,
				drag: VirtualMouseLauncherDrag(startPoint: point)
			)
			if case .button(let button) = interaction {
				for pressed in reducer.down(button).pressed { onButton?(pressed, true) }
			}
		}
		bodyView.heldButtons = reducer.held
	}

	override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
		for touch in touches {
			guard var state = activeTouches[touch] else { continue }
			let point = touch.location(in: self)
			let delta = CGPoint(x: point.x - state.lastPoint.x,
								y: point.y - state.lastPoint.y)
			let dragDelta = state.drag.move(to: point)
			state.lastPoint = point
			if case .wheel = state.interaction {
				state.wheelRemainder += delta.y / 8
			}
			let wheelUnits = Int32(state.wheelRemainder)
			state.wheelRemainder -= CGFloat(wheelUnits)
			activeTouches[touch] = state
			switch state.interaction {
			case .button:
				if delta != .zero { onMove?(delta) }
			case .move:
				if delta != .zero {
					onMove?(delta)
					if activeTouches[touch] != nil { moveBody(by: delta) }
				}
			case .wheel:
				if wheelUnits != 0 { onScroll?(wheelUnits) }
			case .reposition:
				if dragDelta != .zero { moveBody(by: dragDelta) }
			case .resize, .collapse:
				break
			}
		}
	}

	override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
		finishTouches(touches, cancelled: false)
	}

	override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
		finishTouches(touches, cancelled: true)
	}

	private func isButtonHeld(_ button: VirtualMouseButton) -> Bool {
		activeTouches.values.contains { state in
			if case .button(let held) = state.interaction { return held == button }
			return false
		}
	}

	private func finishTouches(_ touches: Set<UITouch>, cancelled: Bool) {
		var collapseTarget: Bool?
		for touch in touches {
			guard var state = activeTouches.removeValue(forKey: touch) else { continue }
			if case .button(let button) = state.interaction {
				for released in reducer.up(button).released { onButton?(released, false) }
				continue
			}
			guard !cancelled, !isHidden, configuration.enabled else { continue }
			let point = touch.location(in: self)
			switch state.interaction {
			case .reposition:
				if state.drag.shouldExpand(at: point, cancelled: cancelled),
				   self.point(inside: point, with: nil) {
					collapseTarget = false
				} else {
					let delta = state.drag.move(to: point)
					if delta != .zero { moveBody(by: delta) }
				}
			case .collapse:
				if state.drag.shouldExpand(at: point, cancelled: cancelled),
				   let layout = localPresentation?.layout,
				   layout.collapseButtonFrame.contains(touch.location(in: bodyView)) {
					collapseTarget = true
				}
			default:
				break
			}
		}
		bodyView.heldButtons = reducer.held
		if let collapsed = collapseTarget { setCollapsed(collapsed) }
	}

	private func moveBody(by delta: CGPoint) {
		guard let presentation = presentation else { return }
		let next = VirtualMouseGeometry.movedPosition(
			for: presentation.bodyFrame, by: delta, in: effectiveUsableRect, insets: safeInsets
		)
		guard next != configuration.normalizedPosition else { return }
		configuration.normalizedPosition = next
		onPositionChanged?(next)
		layoutIfNeeded()
	}

	private var effectiveUsableRect: CGRect {
		usableRect.width > 0 && usableRect.height > 0
			? usableRect
			: CGRect(origin: .zero, size: superview?.bounds.size ?? bounds.size)
	}

	private func updateAccessibility() {
		guard let presentation = presentation else { return }
		if presentation.isCollapsed {
			let launcher = accessibilityControl(label: "展开虚拟鼠标", frame: presentation.bodyFrame)
			launcher.onActivate = { [weak self] in self?.setCollapsedAccessibly(false) }
			launcher.accessibilityHint = "轻点展开，拖动调整位置"
			accessibilityElements = [launcher]
			return
		}
		guard let layout = presentation.layout else { return }
		let left = accessibilityControl(label: "鼠标左键", frame: layout.leftButtonFrame)
		let right = accessibilityControl(label: "鼠标右键", frame: layout.rightButtonFrame)
		for (element, button) in [(left, VirtualMouseButton.left), (right, VirtualMouseButton.right)] {
			element.onActivate = { [weak self] in
				guard let self = self, !self.isHidden, self.configuration.enabled,
					  !self.reducer.held.contains(button) else { return }
				for pressed in self.reducer.down(button).pressed { self.onButton?(pressed, true) }
				for released in self.reducer.up(button).released { self.onButton?(released, false) }
			}
			element.accessibilityHint = "按住并滑动可拖动远端项目"
		}
		let wheel = accessibilityControl(label: "鼠标滚轮", frame: layout.wheelFrame)
		wheel.accessibilityTraits = .adjustable
		wheel.onIncrement = { [weak self] in self?.scrollAccessibly(1) }
		wheel.onDecrement = { [weak self] in self?.scrollAccessibly(-1) }
		let palm = accessibilityControl(label: "鼠标掌托", frame: layout.moveFrame)
		palm.accessibilityTraits = []
		palm.accessibilityHint = "滑动移动指针和鼠标位置"
		let collapse = accessibilityControl(label: "收起虚拟鼠标", frame: layout.collapseButtonFrame)
		collapse.onActivate = { [weak self] in self?.setCollapsedAccessibly(true) }
		accessibilityElements = [left, right, wheel, palm, collapse]
	}

	private func accessibilityControl(label: String, frame: CGRect) -> VirtualMouseAccessibilityElement {
		let element = VirtualMouseAccessibilityElement(accessibilityContainer: self)
		element.accessibilityLabel = label
		element.accessibilityTraits = .button
		element.accessibilityFrameInContainerSpace = frame
		return element
	}

	private func scrollAccessibly(_ units: Int32) {
		guard !isHidden, configuration.enabled else { return }
		onScroll?(units)
	}

	private func setCollapsedAccessibly(_ collapsed: Bool) {
		guard !isHidden, configuration.enabled else { return }
		setCollapsed(collapsed)
	}

	override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
		self.point(inside: point, with: event) ? self : nil
	}
}

private final class VirtualMouseBodyView: UIView {
	var presentation: VirtualMousePresentation? {
		didSet {
			updateShadow()
			setNeedsDisplay()
		}
	}

	var heldButtons: Set<VirtualMouseButton> = [] {
		didSet { setNeedsDisplay() }
	}

	override init(frame: CGRect) {
		super.init(frame: frame)
		isOpaque = false
		backgroundColor = .clear
		layer.shadowColor = UIColor.black.cgColor
		layer.shadowOpacity = 0.18
		layer.shadowRadius = 6
		layer.shadowOffset = CGSize(width: 0, height: 3)
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
		super.traitCollectionDidChange(previousTraitCollection)
		setNeedsDisplay()
	}

	override func draw(_ rect: CGRect) {
		guard let presentation = presentation, let context = UIGraphicsGetCurrentContext() else { return }
		context.clear(bounds)
		if presentation.isCollapsed {
			drawCollapsed(in: bounds)
			return
		}
		guard let layout = presentation.layout else { return }
		let dark = traitCollection.userInterfaceStyle == .dark
		let bodyPath = VirtualMouseGeometry.bodyPath(in: layout.bodyFrame)
		context.saveGState()
		context.addPath(bodyPath)
		context.clip()
		let colors = dark
			? [UIColor(white: 0.27, alpha: 0.92).cgColor, UIColor(white: 0.14, alpha: 0.86).cgColor]
			: [UIColor(white: 0.99, alpha: 0.94).cgColor, UIColor(white: 0.83, alpha: 0.88).cgColor]
		if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: nil) {
			context.drawLinearGradient(gradient, start: CGPoint(x: bounds.midX, y: bounds.minY),
									   end: CGPoint(x: bounds.midX, y: bounds.maxY), options: [])
		}
		for button in [VirtualMouseButton.left, .right] {
			let path = UIBezierPath(cgPath: VirtualMouseGeometry.buttonPath(button, layout: layout))
			let fill = heldButtons.contains(button)
				? UIColor.systemBlue.withAlphaComponent(dark ? 0.55 : 0.25)
				: UIColor.white.withAlphaComponent(dark ? 0.1 : 0.3)
			fill.setFill()
			path.fill()
			UIColor(white: dark ? 1 : 0.2, alpha: dark ? 0.16 : 0.12).setStroke()
			path.lineWidth = 0.8
			path.stroke()
		}
		drawWheel(layout: layout, dark: dark)
		let accent = UIBezierPath()
		accent.move(to: CGPoint(x: bounds.midX - 11, y: bounds.maxY - 20))
		accent.addQuadCurve(to: CGPoint(x: bounds.midX + 11, y: bounds.maxY - 20),
							controlPoint: CGPoint(x: bounds.midX, y: bounds.maxY - 17))
		UIColor(white: dark ? 1 : 0.2, alpha: 0.18).setStroke()
		accent.lineWidth = 1
		accent.lineCapStyle = .round
		accent.stroke()
		context.restoreGState()
		let outline = UIBezierPath(cgPath: bodyPath)
		UIColor(white: dark ? 1 : 0.25, alpha: dark ? 0.24 : 0.22).setStroke()
		outline.lineWidth = 0.8
		outline.stroke()
		let closeFrame = collapseGlyphFrame(layout: layout)
		let close = UIBezierPath(ovalIn: closeFrame)
		UIColor(white: dark ? 0.12 : 0.97, alpha: 0.96).setFill()
		close.fill()
		UIColor(white: dark ? 1 : 0.2, alpha: 0.2).setStroke()
		close.lineWidth = 0.8
		close.stroke()
		VirtualMouseDrawing.glyph("xmark", in: closeFrame.insetBy(dx: 3, dy: 3),
								  color: UIColor(white: dark ? 0.92 : 0.3, alpha: 1))
	}

	private func drawWheel(layout: VirtualMouseLayout, dark: Bool) {
		let frame = VirtualMouseGeometry.wheelTrackFrame(layout: layout)
		let path = UIBezierPath(roundedRect: frame, cornerRadius: frame.width / 2)
		UIColor(white: dark ? 0.08 : 0.35, alpha: 0.82).setFill()
		path.fill()
		let grips = UIBezierPath()
		for index in 0..<5 {
			let vertical = frame.midY + CGFloat(index - 2) * 5
			grips.move(to: CGPoint(x: frame.minX + 3, y: vertical))
			grips.addLine(to: CGPoint(x: frame.maxX - 3, y: vertical))
		}
		UIColor.white.withAlphaComponent(dark ? 0.28 : 0.48).setStroke()
		grips.lineWidth = 1
		grips.lineCapStyle = .round
		grips.stroke()
	}

	private func drawCollapsed(in rect: CGRect) {
		let dark = traitCollection.userInterfaceStyle == .dark
		let path = UIBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
		UIColor(white: dark ? 0.18 : 0.96, alpha: 0.9).setFill()
		path.fill()
		UIColor(white: dark ? 1 : 0.2, alpha: 0.2).setStroke()
		path.lineWidth = 1
		path.stroke()
		VirtualMouseDrawing.glyph("computermouse.fill", in: rect,
								  color: UIColor(white: dark ? 0.95 : 0.3, alpha: 1))
	}

	private func collapseGlyphFrame(layout: VirtualMouseLayout) -> CGRect {
		VirtualMouseGeometry.collapseGlyphFrame(layout: layout)
	}

	private func updateShadow() {
		guard let presentation = presentation else {
			layer.shadowPath = nil
			return
		}
		if presentation.isCollapsed {
			layer.shadowPath = CGPath(ellipseIn: presentation.bodyFrame.insetBy(dx: 0.5, dy: 0.5), transform: nil)
		} else if let layout = presentation.layout {
			let path = CGMutablePath()
			path.addPath(VirtualMouseGeometry.bodyPath(in: layout.bodyFrame))
			path.addEllipse(in: collapseGlyphFrame(layout: layout))
			layer.shadowPath = path
		}
	}
}

private final class VirtualMouseAccessibilityElement: UIAccessibilityElement {
	var onActivate: (() -> Void)?
	var onIncrement: (() -> Void)?
	var onDecrement: (() -> Void)?

	override func accessibilityActivate() -> Bool {
		guard let onActivate = onActivate else { return false }
		onActivate()
		return true
	}

	override func accessibilityIncrement() {
		onIncrement?()
	}

	override func accessibilityDecrement() {
		onDecrement?()
	}
}

private enum VirtualMouseDrawing {
	static func glyph(_ name: String, in frame: CGRect, color: UIColor) {
		guard let image = UIImage(systemName: name)?.withTintColor(color, renderingMode: .alwaysOriginal)
		else { return }
		let size = CGSize(width: max(0, min(24, frame.width - 6)),
						  height: max(0, min(24, frame.height - 6)))
		image.draw(in: CGRect(x: frame.midX - size.width / 2,
							  y: frame.midY - size.height / 2,
							  width: size.width, height: size.height))
	}
}
