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
	static let minimumScale: CGFloat = 0.75
	static let maximumScale: CGFloat = 1.4

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
		return frames.allSatisfy { bodyFrame.contains($0) }
	}

	var isValid: Bool {
		let controls = [leftButtonFrame, rightButtonFrame, middleButtonFrame, wheelFrame]
		let topControls = [repositionHandleFrame, collapseButtonFrame]
		guard controls.allSatisfy({
			$0.width >= VirtualMouseGeometry.minimumButtonLength &&
			$0.height >= VirtualMouseGeometry.minimumButtonLength
		}) else { return false }
		guard topControls.allSatisfy({
			$0.width >= VirtualMouseGeometry.minimumButtonLength &&
			$0.height >= VirtualMouseGeometry.minimumButtonLength
		}) else { return false }
		guard repositionHandleFrame.maxX <= collapseButtonFrame.minX else { return false }
		guard resizeHandleFrame.minY >= (topControls.map(\.maxY).max() ?? 0) else { return false }
		guard moveFrame.minY >= leftButtonFrame.maxY else { return false }
		guard moveFrame.maxY <= bodyFrame.maxY + 0.5 else { return false }
		let allControls = topControls + controls
		guard !resizeHandleFrame.intersects(repositionHandleFrame),
			  !resizeHandleFrame.intersects(collapseButtonFrame),
			  !resizeHandleFrame.intersects(leftButtonFrame),
			  !resizeHandleFrame.intersects(rightButtonFrame),
			  !resizeHandleFrame.intersects(middleButtonFrame),
			  !resizeHandleFrame.intersects(wheelFrame) else { return false }
		guard resizeHandleFrame.intersects(moveFrame) else { return false }
		for index in allControls.indices {
			for other in allControls.indices where other > index {
				if allControls[index].intersects(allControls[other]) { return false }
			}
		}
		guard !moveFrame.intersects(leftButtonFrame),
			  !moveFrame.intersects(rightButtonFrame),
			  !moveFrame.intersects(middleButtonFrame),
			  !moveFrame.intersects(wheelFrame),
			  moveFrame.width >= VirtualMouseGeometry.minimumButtonLength,
			  moveFrame.height >= VirtualMouseGeometry.minimumButtonLength else { return false }
		return true
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

enum VirtualMouseGeometry {
	static let baseBodySize = CGSize(width: 240, height: 320)
	static let collapsedSize: CGFloat = 44
	static let minimumButtonLength: CGFloat = 44
	static let padding: CGFloat = 6
	static let gap: CGFloat = 6

	static let minimumExpandedScale = max(
		(padding * 2 + minimumButtonLength * 2 + gap) / baseBodySize.width,
		(padding * 2 + minimumButtonLength * 4 + gap * 3) / baseBodySize.height
	)

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
		let topHeight = minimumButtonLength
		let topY = bodyFrame.minY + padding
		let topControlWidth = max(
			minimumButtonLength,
			min(64, (bodyFrame.width - padding * 2 - gap) / 2)
		)
		let reposition = CGRect(
			x: bodyFrame.minX + padding,
			y: topY,
			width: topControlWidth,
			height: topHeight
		)
		let collapse = CGRect(
			x: bodyFrame.maxX - padding - topControlWidth,
			y: topY,
			width: topControlWidth,
			height: topHeight
		)
		let buttonRowY = topY + topHeight + gap
		let smallButtonWidth = max(
			minimumButtonLength,
			(bodyFrame.width - padding * 2 - gap * 2 - minimumButtonLength) / 2
		)
		let fixedHeight = padding * 2 + topHeight + gap * 3
		let availableButtonHeight = bodyFrame.height - fixedHeight
		let buttonHeight = max(minimumButtonLength,
							   min(70, bodyFrame.height * 0.25, availableButtonHeight))
		let left = CGRect(
			x: bodyFrame.minX + padding,
			y: buttonRowY,
			width: smallButtonWidth,
			height: buttonHeight
		)
		let right = CGRect(
			x: bodyFrame.maxX - padding - smallButtonWidth,
			y: buttonRowY,
			width: smallButtonWidth,
			height: buttonHeight
		)
		let middle = CGRect(
			x: bodyFrame.midX - minimumButtonLength / 2,
			y: buttonRowY,
			width: minimumButtonLength,
			height: buttonHeight
		)
		let wheelY = left.maxY + gap
		let wheel = CGRect(
			x: bodyFrame.minX + padding,
			y: wheelY,
			width: max(0, bodyFrame.width - padding * 2),
			height: minimumButtonLength
		)
		let moveY = wheel.maxY + gap
		let move = CGRect(
			x: bodyFrame.minX + padding,
			y: moveY,
			width: max(0, bodyFrame.width - padding * 2),
			height: max(0, bodyFrame.maxY - padding - moveY)
		)
		return VirtualMouseLayout(
			bodyFrame: bodyFrame,
			repositionHandleFrame: reposition,
			leftButtonFrame: left,
			rightButtonFrame: right,
			middleButtonFrame: middle,
			wheelFrame: wheel,
			moveFrame: move,
			collapseButtonFrame: collapse,
			resizeHandleFrame: CGRect(
				x: bodyFrame.maxX - padding - 44,
				y: bodyFrame.maxY - padding - 44,
				width: 44,
				height: 44
			)
		)
	}

	static func interaction(at point: CGPoint, layout: VirtualMouseLayout) -> VirtualMouseInteraction? {
		if layout.collapseButtonFrame.contains(point) { return .collapse }
		if layout.repositionHandleFrame.contains(point) { return .reposition }
		if layout.resizeHandleFrame.contains(point) { return .resize }
		if layout.leftButtonFrame.contains(point) { return .button(.left) }
		if layout.rightButtonFrame.contains(point) { return .button(.right) }
		if layout.middleButtonFrame.contains(point) { return .button(.middle) }
		if layout.wheelFrame.contains(point) { return .wheel }
		if layout.moveFrame.contains(point) { return .move }
		return nil
	}

	static func fittedScale(_ requested: CGFloat, in usableRect: CGRect) -> CGFloat {
		let requestedScale = requested.isFinite ? requested : VirtualMouseConfiguration.defaultScale
		let scale = min(max(VirtualMouseConfiguration.minimumScale, requestedScale),
						VirtualMouseConfiguration.maximumScale)
		return min(scale,
				   min(usableRect.width / baseBodySize.width,
					   usableRect.height / baseBodySize.height))
	}

	static func canFitExpandedBody(in usableRect: CGRect) -> Bool {
		let maxScale = min(usableRect.width / baseBodySize.width,
						   usableRect.height / baseBodySize.height)
		guard maxScale >= minimumExpandedScale else { return false }
		guard maxScale >= VirtualMouseConfiguration.minimumScale else { return false }
		let scaledGate = usableRect.width >= minimumExpandedSize.width &&
			usableRect.height >= minimumExpandedSize.height
		let probe = CGSize(width: baseBodySize.width * maxScale,
						   height: baseBodySize.height * maxScale)
		return scaledGate && layout(
			bodyFrame: CGRect(origin: .zero, size: probe),
			scale: maxScale
		).isValid
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
