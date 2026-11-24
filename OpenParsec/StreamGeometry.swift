import CoreGraphics
import UIKit

enum StreamDisplayMode: Int {
	case fill = 0
	case fit = 1
}

struct StreamGeometry {
	let viewportSize: CGSize
	let hostSize: CGSize
	let mode: StreamDisplayMode

	var validSize: Bool {
		guard hostSize.width > 0, hostSize.height > 0,
			  viewportSize.width > 0, viewportSize.height > 0 else { return false }
		return true
	}

	var horizontalScale: CGFloat {
		guard validSize else { return 1 }
		return viewportSize.width / hostSize.width
	}

	var verticalScale: CGFloat {
		guard validSize else { return 1 }
		return viewportSize.height / hostSize.height
	}

	var scale: CGFloat {
		guard validSize else { return 1 }
		return mode == .fill ? horizontalScale : min(horizontalScale, verticalScale)
	}

	var contentSize: CGSize {
		guard validSize else { return viewportSize }
		switch mode {
		case .fill:
			return viewportSize
		case .fit:
			return CGSize(width: hostSize.width * scale, height: hostSize.height * scale)
		}
	}

	var contentOffset: CGPoint {
		CGPoint(x: (contentSize.width - viewportSize.width) / 2,
				y: (contentSize.height - viewportSize.height) / 2)
	}

	var contentRect: CGRect {
		CGRect(origin: .zero, size: contentSize)
	}

	var scrollOffset: CGPoint {
		switch mode {
		case .fill:
			return .zero
		case .fit:
			return CGPoint(x: max(0, contentOffset.x), y: max(0, contentOffset.y))
		}
	}

	var visibleHostRect: CGRect {
		guard horizontalScale > 0, verticalScale > 0 else { return CGRect(origin: .zero, size: hostSize) }
		return CGRect(x: scrollOffset.x / horizontalScale,
					  y: scrollOffset.y / verticalScale,
					  width: viewportSize.width / horizontalScale,
					  height: viewportSize.height / verticalScale)
	}

	// ParsecClientSetDimensions accepts one scale for both axes. Fill stretches each axis
	// independently, so the SDK scale is only used for input translation; renderers use the
	// exact horizontalScale/verticalScale instead.
	var sdkScale: CGFloat {
		switch mode {
		case .fill:
			guard validSize else { return UIScreen.main.scale }
			return (horizontalScale + verticalScale) / 2
		case .fit:
			return UIScreen.main.scale
		}
	}

	static func sdkScale(for geometry: StreamGeometry) -> CGFloat {
		geometry.sdkScale
	}

	func screenPoint(forHostPoint point: CGPoint) -> CGPoint {
		CGPoint(x: point.x * horizontalScale,
				y: point.y * verticalScale)
	}

	func hostPoint(forScreenPoint point: CGPoint) -> CGPoint {
		CGPoint(x: point.x / horizontalScale,
				y: point.y / verticalScale)
	}
}
