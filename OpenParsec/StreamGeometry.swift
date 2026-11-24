import CoreGraphics
import UIKit

enum StreamDisplayMode: Int {
	case adaptive = 0
	case original = 1
}

struct AdaptiveHostResolution: Equatable {
	let width: Int
	let height: Int

	static func target(for viewportSize: CGSize) -> AdaptiveHostResolution? {
		guard viewportSize.width > viewportSize.height, viewportSize.height > 0 else { return nil }
		let scale = UIScreen.main.nativeScale
		let screenWidth = Int((viewportSize.width * scale).rounded())
		let screenHeight = Int((viewportSize.height * scale).rounded())
		guard screenWidth > screenHeight else { return nil }

		let maxWidth = even(Double(min(1920, screenWidth)))
		let maxHeight = even(Double(min(1080, screenHeight)))
		guard maxWidth >= 640, maxHeight >= 360 else { return nil }

		let widthAtHeightLimit = even(Double(maxHeight) * Double(screenWidth) / Double(screenHeight))
		if widthAtHeightLimit > 0 && widthAtHeightLimit <= maxWidth {
			return AdaptiveHostResolution(width: widthAtHeightLimit, height: maxHeight)
		}
		let heightAtWidthLimit = even(Double(maxWidth) * Double(screenHeight) / Double(screenWidth))
		guard heightAtWidthLimit > 0 else { return nil }
		return AdaptiveHostResolution(width: maxWidth, height: heightAtWidthLimit)
	}

	static func currentViewportSize(preferring size: CGSize) -> CGSize {
		if size.width > 0, size.height > 0 { return size }
		let window = UIApplication.shared.connectedScenes
			.compactMap { $0 as? UIWindowScene }
			.flatMap { $0.windows }
			.first { $0.isKeyWindow }
		return window?.bounds.size ?? UIScreen.main.bounds.size
	}

	private static func even(_ value: Double) -> Int {
		let rounded = Int(value.rounded())
		return max(0, rounded - rounded % 2)
	}
}

struct StreamGeometry {
	let viewportSize: CGSize
	let hostSize: CGSize

	var validSize: Bool {
		guard hostSize.width > 0, hostSize.height > 0,
			  viewportSize.width > 0, viewportSize.height > 0 else { return false }
		return true
	}

	var scale: CGFloat {
		guard validSize else { return 1 }
		return min(viewportSize.width / hostSize.width, viewportSize.height / hostSize.height)
	}

	var horizontalScale: CGFloat { scale }
	var verticalScale: CGFloat { scale }

	var contentSize: CGSize {
		guard validSize else { return viewportSize }
		return CGSize(width: hostSize.width * scale, height: hostSize.height * scale)
	}

	var contentOffset: CGPoint {
		CGPoint(x: (contentSize.width - viewportSize.width) / 2,
				y: (contentSize.height - viewportSize.height) / 2)
	}

	var contentRect: CGRect {
		CGRect(origin: .zero, size: contentSize)
	}

	var scrollOffset: CGPoint {
		CGPoint(x: max(0, contentOffset.x), y: max(0, contentOffset.y))
	}

	var visibleHostRect: CGRect {
		guard scale > 0 else { return CGRect(origin: .zero, size: hostSize) }
		return CGRect(x: scrollOffset.x / scale,
					  y: scrollOffset.y / scale,
					  width: viewportSize.width / scale,
					  height: viewportSize.height / scale)
	}

	func screenPoint(forHostPoint point: CGPoint) -> CGPoint {
		CGPoint(x: point.x * scale, y: point.y * scale)
	}

	func hostPoint(forScreenPoint point: CGPoint) -> CGPoint {
		CGPoint(x: point.x / scale, y: point.y / scale)
	}
}
