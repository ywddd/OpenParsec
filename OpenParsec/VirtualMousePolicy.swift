import Foundation
import CoreGraphics

enum VirtualMouseButton: CaseIterable, Hashable {
	case left
	case right
	case middle
}

enum VirtualMouseInteraction: Hashable {
	case button(VirtualMouseButton)
	case move
	case wheel
	case reposition
	case collapse
	case resize
}

struct VirtualMouseInsets: Equatable {
	var top: CGFloat = 0
	var left: CGFloat = 0
	var bottom: CGFloat = 0
	var right: CGFloat = 0

	static let zero = VirtualMouseInsets()
}

struct VirtualMouseConfiguration: Equatable {
	var enabled: Bool
	var scale: CGFloat
	var normalizedPosition: CGPoint

	static let defaultScale: CGFloat = 1
	static let defaultPosition = CGPoint(x: 0.8, y: 0.65)
	static let minimumScale = VirtualMouseGeometry.minimumBodyWidth / VirtualMouseGeometry.baseBodySize.width
	static let maximumScale = VirtualMouseGeometry.maximumBodyWidth / VirtualMouseGeometry.baseBodySize.width

	init(enabled: Bool, scale: CGFloat, normalizedPosition: CGPoint) {
		self.enabled = enabled
		self.scale = Self.clampedScale(scale)
		let x = normalizedPosition.x.isFinite ? normalizedPosition.x : Self.defaultPosition.x
		let y = normalizedPosition.y.isFinite ? normalizedPosition.y : Self.defaultPosition.y
		self.normalizedPosition = CGPoint(x: min(max(0, x), 1), y: min(max(0, y), 1))
	}

	static func clampedScale(_ scale: CGFloat) -> CGFloat {
		guard scale.isFinite else { return defaultScale }
		return min(maximumScale, max(minimumScale, scale))
	}
}

struct VirtualMouseButtonTransition: Equatable {
	let pressed: [VirtualMouseButton]
	let released: [VirtualMouseButton]
}

struct VirtualMouseButtonReducer: Equatable {
	private(set) var held: Set<VirtualMouseButton> = []

	mutating func down(_ button: VirtualMouseButton) -> VirtualMouseButtonTransition {
		VirtualMouseButtonTransition(pressed: held.insert(button).inserted ? [button] : [], released: [])
	}

	mutating func up(_ button: VirtualMouseButton) -> VirtualMouseButtonTransition {
		VirtualMouseButtonTransition(pressed: [], released: held.remove(button) == nil ? [] : [button])
	}

	mutating func cancelAll() -> VirtualMouseButtonTransition {
		let released = VirtualMouseButton.allCases.filter { held.contains($0) }
		held.removeAll()
		return VirtualMouseButtonTransition(pressed: [], released: released)
	}
}

struct VirtualMouseLayout: Equatable {
	let bodyFrame: CGRect
	let repositionHandleFrame: CGRect
	let leftButtonFrame: CGRect
	let rightButtonFrame: CGRect
	let middleButtonFrame: CGRect
	let wheelFrame: CGRect
	let moveFrame: CGRect
	let collapseButtonFrame: CGRect
	let resizeHandleFrame: CGRect

	var isContainedInBody: Bool {
		let frames = [repositionHandleFrame, leftButtonFrame, rightButtonFrame,
					  middleButtonFrame, wheelFrame, moveFrame,
					  collapseButtonFrame, resizeHandleFrame]
		return frames.filter { !$0.isEmpty }.allSatisfy { bodyFrame.contains($0) }
	}

	var isValid: Bool {
		guard [leftButtonFrame, rightButtonFrame].allSatisfy({
			$0.width >= VirtualMouseGeometry.minimumButtonLength &&
			$0.height >= VirtualMouseGeometry.minimumButtonLength
		}), moveFrame.width >= VirtualMouseGeometry.minimumButtonLength,
			  moveFrame.height >= VirtualMouseGeometry.minimumPalmHeight else { return false }
		let controls = [leftButtonFrame, rightButtonFrame, moveFrame, wheelFrame, collapseButtonFrame]
		guard bodyFrame.width <= VirtualMouseGeometry.maximumBodyWidth + 0.5,
			  bodyFrame.width >= VirtualMouseGeometry.minimumBodyWidth - 0.5,
			  collapseButtonFrame.width >= VirtualMouseGeometry.minimumCollapseHitSize,
			  collapseButtonFrame.height >= VirtualMouseGeometry.minimumCollapseHitSize,
			  controls.allSatisfy({ bodyFrame.contains($0) }),
			  wheelFrame.width >= VirtualMouseGeometry.minimumWheelWidth,
			  wheelFrame.height >= VirtualMouseGeometry.minimumWheelHeight,
			  !leftButtonFrame.intersects(rightButtonFrame),
			  repositionHandleFrame.isEmpty,
			  middleButtonFrame.isEmpty,
			  resizeHandleFrame.isEmpty else { return false }
		guard !moveFrame.intersects(leftButtonFrame),
			  !moveFrame.intersects(rightButtonFrame),
			  !moveFrame.intersects(wheelFrame),
			  !moveFrame.intersects(collapseButtonFrame),
			  !collapseButtonFrame.intersects(leftButtonFrame),
			  !collapseButtonFrame.intersects(rightButtonFrame),
			  !collapseButtonFrame.intersects(wheelFrame) else { return false }
		return isContainedInBody
	}
}

struct VirtualMousePresentation: Equatable {
	let isCollapsed: Bool
	let scale: CGFloat
	let bodyFrame: CGRect
	let layout: VirtualMouseLayout?

	static func collapsed(at position: CGPoint, scale: CGFloat) -> VirtualMousePresentation {
		VirtualMousePresentation(
			isCollapsed: true,
			scale: scale,
			bodyFrame: CGRect(origin: position,
							  size: CGSize(width: VirtualMouseGeometry.collapsedSize,
										   height: VirtualMouseGeometry.collapsedSize)),
			layout: nil
		)
	}

	var localizedToBody: VirtualMousePresentation {
		VirtualMousePresentation(
			isCollapsed: isCollapsed,
			scale: scale,
			bodyFrame: CGRect(origin: .zero, size: bodyFrame.size),
			layout: layout?.offsetBy(dx: -bodyFrame.minX, dy: -bodyFrame.minY)
		)
	}
}

extension VirtualMouseLayout {
	func offsetBy(dx: CGFloat, dy: CGFloat) -> VirtualMouseLayout {
		VirtualMouseLayout(
			bodyFrame: bodyFrame.offsetBy(dx: dx, dy: dy),
			repositionHandleFrame: repositionHandleFrame.offsetBy(dx: dx, dy: dy),
			leftButtonFrame: leftButtonFrame.offsetBy(dx: dx, dy: dy),
			rightButtonFrame: rightButtonFrame.offsetBy(dx: dx, dy: dy),
			middleButtonFrame: middleButtonFrame.offsetBy(dx: dx, dy: dy),
			wheelFrame: wheelFrame.offsetBy(dx: dx, dy: dy),
			moveFrame: moveFrame.offsetBy(dx: dx, dy: dy),
			collapseButtonFrame: collapseButtonFrame.offsetBy(dx: dx, dy: dy),
			resizeHandleFrame: resizeHandleFrame.offsetBy(dx: dx, dy: dy)
		)
	}
}

enum VirtualMouseLauncherGeometry {
	static func frame(for bodyFrame: CGRect, in usableRect: CGRect) -> CGRect {
		let size = VirtualMouseGeometry.collapsedSize
		let maxX = max(usableRect.minX, usableRect.maxX - size)
		let maxY = max(usableRect.minY, usableRect.maxY - size)
		return CGRect(
			x: min(max(usableRect.minX, bodyFrame.minX), maxX),
			y: min(max(usableRect.minY, bodyFrame.minY), maxY),
			width: size,
			height: size
		)
	}
}

struct VirtualMouseLauncherDrag: Equatable {
	static let movementThreshold: CGFloat = 8
	let startPoint: CGPoint
	private(set) var lastPoint: CGPoint
	private(set) var isDragging = false

	init(startPoint: CGPoint) {
		self.startPoint = startPoint
		self.lastPoint = startPoint
	}

	mutating func move(to point: CGPoint) -> CGPoint {
		let previousPoint = lastPoint
		lastPoint = point
		if !isDragging {
			guard exceedsThreshold(at: point) else { return .zero }
			isDragging = true
			return CGPoint(x: point.x - startPoint.x, y: point.y - startPoint.y)
		}
		return CGPoint(x: point.x - previousPoint.x, y: point.y - previousPoint.y)
	}

	func shouldExpand(at point: CGPoint, cancelled: Bool) -> Bool {
		!cancelled && !isDragging && !exceedsThreshold(at: point)
	}

	private func exceedsThreshold(at point: CGPoint) -> Bool {
		let horizontal = point.x - startPoint.x
		let vertical = point.y - startPoint.y
		return horizontal * horizontal + vertical * vertical > Self.movementThreshold * Self.movementThreshold
	}
}

enum VirtualMouseGeometry {
	static let baseBodySize = CGSize(width: 136, height: 180)
	static let minimumBodyWidth: CGFloat = 132
	static let maximumBodyWidth: CGFloat = 160
	static let collapsedSize: CGFloat = 46
	static let minimumButtonLength: CGFloat = 44
	static let minimumPalmHeight: CGFloat = 40
	static let minimumCollapseHitSize: CGFloat = 24
	static let collapseTailInset: CGFloat = 1
	static let minimumWheelWidth: CGFloat = 44
	static let minimumWheelHeight: CGFloat = 72
	static let wheelTrackWidth: CGFloat = 12
	static let wheelHoldStep: CGFloat = 0.35
	static let wheelMeaningfulMovement: CGFloat = 4
	static let wheelHoldDelay: TimeInterval = 0.25
	static let wheelHoldInterval: TimeInterval = 0.06
	static let padding: CGFloat = 4
	static let gap: CGFloat = 4

	static let minimumExpandedScale = VirtualMouseConfiguration.minimumScale

	static let minimumExpandedSize = CGSize(
		width: baseBodySize.width * minimumExpandedScale,
		height: baseBodySize.height * minimumExpandedScale
	)

	static func normalizedPosition(_ point: CGPoint) -> CGPoint {
		CGPoint(x: unit(point.x), y: unit(point.y))
	}

	static func presentation(
		configuration: VirtualMouseConfiguration,
		in usableRect: CGRect,
		insets: VirtualMouseInsets = .zero,
		collapsed: Bool
	) -> VirtualMousePresentation {
		let bounds = safeBounds(usableRect, insets: insets)
		let collapsedFrame = collapsedFrame(normalizedPosition: configuration.normalizedPosition,
											in: bounds)
		guard !collapsed else {
			let launcher = VirtualMouseLauncherGeometry.frame(for: collapsedFrame, in: bounds)
			return .collapsed(at: launcher.origin, scale: configuration.scale)
		}
		guard canFitExpandedBody(in: bounds) else {
			return .collapsed(at: collapsedFrame.origin, scale: configuration.scale)
		}
		let scale = fittedScale(configuration.scale, in: bounds)
		guard scale > 0 else {
			return .collapsed(at: collapsedFrame.origin, scale: configuration.scale)
		}
		let size = CGSize(width: baseBodySize.width * scale,
						  height: baseBodySize.height * scale)
		let bodyFrame = clampedBodyFrame(
			normalizedPosition: configuration.normalizedPosition,
			size: size,
			in: bounds
		)
		let candidate = layout(bodyFrame: bodyFrame, scale: scale)
		guard candidate.isValid && candidate.isContainedInBody else {
			return .collapsed(at: collapsedFrame.origin, scale: configuration.scale)
		}
		return VirtualMousePresentation(
			isCollapsed: false,
			scale: scale,
			bodyFrame: bodyFrame,
			layout: candidate
		)
	}

	static func layout(bodyFrame: CGRect, scale: CGFloat) -> VirtualMouseLayout {
		let padding = max(Self.padding, Self.padding * scale)
		let gap = max(Self.gap, Self.gap * scale)
		let buttonWidth = (bodyFrame.width - padding * 2 - wheelTrackWidth) / 2
		let wheelHitWidth = max(minimumWheelWidth, min(52, 48 * scale))
		let buttonTop = bodyFrame.minY + bodyFrame.height * 0.06
		let buttonBottom = bodyFrame.minY + bodyFrame.height * 0.50
		let collapse = CGRect(
			x: bodyFrame.midX - minimumCollapseHitSize / 2,
			y: bodyFrame.maxY - minimumCollapseHitSize - collapseTailInset,
			width: minimumCollapseHitSize,
			height: minimumCollapseHitSize
		)
		let left = CGRect(
			x: bodyFrame.minX + padding,
			y: buttonTop,
			width: buttonWidth,
			height: buttonBottom - buttonTop
		)
		let right = CGRect(
			x: bodyFrame.maxX - padding - buttonWidth,
			y: left.minY,
			width: buttonWidth,
			height: left.height
		)
		let wheel = CGRect(
			x: bodyFrame.midX - wheelHitWidth / 2,
			y: bodyFrame.minY + bodyFrame.height * 0.13,
			width: wheelHitWidth,
			height: max(minimumWheelHeight, min(84, 78 * scale))
		)
		let moveY = max(bodyFrame.minY + bodyFrame.height * 0.56, wheel.maxY + gap)
		let moveBottom = min(bodyFrame.maxY - padding, collapse.minY - gap)
		let move = CGRect(
			x: bodyFrame.minX + padding,
			y: moveY,
			width: max(0, bodyFrame.width - padding * 2),
			height: max(0, moveBottom - moveY)
		)
		return VirtualMouseLayout(
			bodyFrame: bodyFrame,
			repositionHandleFrame: .null,
			leftButtonFrame: left,
			rightButtonFrame: right,
			middleButtonFrame: .null,
			wheelFrame: wheel,
			moveFrame: move,
			collapseButtonFrame: collapse,
			resizeHandleFrame: .null
		)
	}

	static func interaction(at point: CGPoint, layout: VirtualMouseLayout) -> VirtualMouseInteraction? {
		guard bodyPath(in: layout.bodyFrame).contains(point) else { return nil }
		if layout.wheelFrame.contains(point) { return .wheel }
		if layout.collapseButtonFrame.contains(point) { return .collapse }
		if buttonPath(.left, layout: layout).contains(point) { return .button(.left) }
		if buttonPath(.right, layout: layout).contains(point) { return .button(.right) }
		return .move
	}

	static func contains(_ point: CGPoint, in presentation: VirtualMousePresentation) -> Bool {
		if presentation.isCollapsed {
			return CGPath(ellipseIn: presentation.bodyFrame.insetBy(dx: 0.5, dy: 0.5), transform: nil).contains(point)
		}
		guard let layout = presentation.layout else { return false }
		return bodyPath(in: presentation.bodyFrame).contains(point)
	}

	static func bodyPath(in frame: CGRect) -> CGPath {
		let outline = frame.insetBy(dx: 1.5, dy: 1.5)
		func point(_ horizontal: CGFloat, _ vertical: CGFloat) -> CGPoint {
			CGPoint(x: outline.minX + outline.width * horizontal,
					y: outline.minY + outline.height * vertical)
		}
		let path = CGMutablePath()
		path.move(to: point(0.38, 0.02))
		path.addCurve(to: point(0.62, 0.02), control1: point(0.45, -0.02), control2: point(0.55, -0.02))
		path.addCurve(to: point(0.94, 0.20), control1: point(0.82, 0.02), control2: point(0.94, 0.08))
		path.addCurve(to: point(0.88, 0.70), control1: point(0.96, 0.40), control2: point(0.98, 0.58))
		path.addCurve(to: point(0.65, 0.98), control1: point(0.82, 0.90), control2: point(0.72, 1.0))
		path.addCurve(to: point(0.35, 0.98), control1: point(0.50, 1.0), control2: point(0.28, 0.90))
		path.addCurve(to: point(0.12, 0.70), control1: point(0.18, 0.98), control2: point(0.04, 0.58))
		path.addCurve(to: point(0.06, 0.20), control1: point(0.02, 0.45), control2: point(0.06, 0.25))
		path.addCurve(to: point(0.38, 0.02), control1: point(0.05, 0.08), control2: point(0.18, 0.02))
		path.closeSubpath()
		return path
	}

	static func buttonPath(_ button: VirtualMouseButton, layout: VirtualMouseLayout) -> CGPath {
		let path = CGMutablePath()
		guard button != .middle else { return path }
		let frame = button == .left ? layout.leftButtonFrame : layout.rightButtonFrame
		let outerX = button == .left ? frame.minX : frame.maxX
		let channelHalfWidth = wheelTrackWidth / 2
		let channelX = layout.bodyFrame.midX + (button == .left ? -channelHalfWidth : channelHalfWidth)
		path.move(to: CGPoint(x: channelX, y: frame.minY))
		path.addLine(to: CGPoint(x: channelX, y: frame.maxY - 8))
		path.addCurve(
			to: CGPoint(x: outerX, y: frame.maxY - 14),
			control1: CGPoint(x: channelX, y: frame.maxY + 2),
			control2: CGPoint(x: outerX, y: frame.maxY - 4)
		)
		path.addLine(to: CGPoint(x: outerX, y: frame.minY))
		path.closeSubpath()
		return path
	}

	static func wheelTrackFrame(layout: VirtualMouseLayout) -> CGRect {
		let height = min(36, layout.wheelFrame.height)
		return CGRect(x: layout.bodyFrame.midX - wheelTrackWidth / 2,
					  y: layout.wheelFrame.midY - height / 2,
					  width: wheelTrackWidth, height: height)
	}

	static func collapseGlyphFrame(layout: VirtualMouseLayout) -> CGRect {
		CGRect(x: layout.collapseButtonFrame.midX - 8, y: layout.collapseButtonFrame.midY - 8,
			   width: 16, height: 16)
	}

	static func wheelUnits(for delta: CGFloat, sensitivity: CGFloat = 1.5,
						  remainder: CGFloat) -> (units: Int32, remainder: CGFloat) {
		let effectiveSensitivity = sensitivity.isFinite ? max(0, sensitivity) : 1.5
		let accumulated = remainder + delta * effectiveSensitivity * 2.3
		let nearestInteger = accumulated.rounded()
		let normalized = abs(accumulated - nearestInteger) <= 1e-9 ? nearestInteger : accumulated
		let units = Int32(normalized)
		return (units, normalized - CGFloat(units))
	}

	static func wheelHoldUnits(direction: CGFloat, sensitivity: CGFloat = 1.5,
							   remainder: CGFloat) -> (units: Int32, remainder: CGFloat) {
		let normalizedDirection: CGFloat = direction > 0 ? 1 : (direction < 0 ? -1 : 0)
		return wheelUnits(for: normalizedDirection * wheelHoldStep,
						  sensitivity: sensitivity, remainder: remainder)
	}

	static func movedPosition(for bodyFrame: CGRect, by delta: CGPoint,
							  in usableRect: CGRect, insets: VirtualMouseInsets = .zero) -> CGPoint {
		let bounds = safeBounds(usableRect, insets: insets)
		let horizontalSpan = max(0, bounds.width - bodyFrame.width)
		let verticalSpan = max(0, bounds.height - bodyFrame.height)
		return CGPoint(
			x: horizontalSpan > 0 ? unit((bodyFrame.minX + delta.x - bounds.minX) / horizontalSpan) : 0,
			y: verticalSpan > 0 ? unit((bodyFrame.minY + delta.y - bounds.minY) / verticalSpan) : 0
		)
	}

	static func fittedScale(_ requested: CGFloat, in usableRect: CGRect) -> CGFloat {
		let scale = VirtualMouseConfiguration.clampedScale(requested)
		return min(scale,
				   min(usableRect.width / baseBodySize.width,
					   usableRect.height / baseBodySize.height))
	}

	static func canFitExpandedBody(in usableRect: CGRect) -> Bool {
		let maxScale = min(usableRect.width / baseBodySize.width,
						   usableRect.height / baseBodySize.height)
		guard maxScale >= minimumExpandedScale else { return false }
		return usableRect.width >= minimumExpandedSize.width &&
			usableRect.height >= baseBodySize.height * VirtualMouseConfiguration.minimumScale
	}

	private static func collapsedFrame(normalizedPosition: CGPoint, in usableRect: CGRect) -> CGRect {
		let normalized = Self.normalizedPosition(normalizedPosition)
		return CGRect(
			x: usableRect.minX + normalized.x * max(0, usableRect.width - collapsedSize),
			y: usableRect.minY + normalized.y * max(0, usableRect.height - collapsedSize),
			width: collapsedSize,
			height: collapsedSize
		)
	}

	private static func clampedBodyFrame(normalizedPosition: CGPoint, size: CGSize,
										 in usableRect: CGRect) -> CGRect {
		let normalized = Self.normalizedPosition(normalizedPosition)
		return CGRect(
			x: usableRect.minX + normalized.x * max(0, usableRect.width - size.width),
			y: usableRect.minY + normalized.y * max(0, usableRect.height - size.height),
			width: size.width,
			height: size.height
		)
	}

	private static func safeBounds(_ rect: CGRect, insets: VirtualMouseInsets) -> CGRect {
		let width = max(0, rect.width - insets.left - insets.right)
		let height = max(0, rect.height - insets.top - insets.bottom)
		return CGRect(x: rect.minX + insets.left, y: rect.minY + insets.top,
					  width: width, height: height)
	}

	private static func unit(_ value: CGFloat) -> CGFloat {
		guard value.isFinite else { return 0.5 }
		return min(max(0, value), 1)
	}
}
