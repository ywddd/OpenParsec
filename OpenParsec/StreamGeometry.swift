import CoreGraphics

enum StreamDisplayMode: Int {
	case fill = 0
	case fit = 1
}

struct StreamGeometry {
	let viewportSize: CGSize
	let hostSize: CGSize
	let mode: StreamDisplayMode

	var scale: CGFloat {
		guard hostSize.width > 0, hostSize.height > 0,
			  viewportSize.width > 0, viewportSize.height > 0 else { return 1 }
		let horizontal = viewportSize.width / hostSize.width
		let vertical = viewportSize.height / hostSize.height
		return mode == .fill ? max(horizontal, vertical) : min(horizontal, vertical)
	}

	var contentSize: CGSize {
		CGSize(width: hostSize.width * scale, height: hostSize.height * scale)
	}

	var contentOffset: CGPoint {
		CGPoint(x: (contentSize.width - viewportSize.width) / 2,
				y: (contentSize.height - viewportSize.height) / 2)
	}

	var contentRect: CGRect {
		CGRect(origin: contentOffset, size: contentSize)
	}

	var visibleHostRect: CGRect {
		guard scale > 0 else { return CGRect(origin: .zero, size: hostSize) }
		return CGRect(x: contentOffset.x / scale,
					  y: contentOffset.y / scale,
					  width: viewportSize.width / scale,
					  height: viewportSize.height / scale)
	}

	func screenPoint(forHostPoint point: CGPoint) -> CGPoint {
		CGPoint(x: point.x * scale - contentOffset.x,
				y: point.y * scale - contentOffset.y)
	}

	func hostPoint(forScreenPoint point: CGPoint) -> CGPoint {
		CGPoint(x: (point.x + contentOffset.x) / scale,
				y: (point.y + contentOffset.y) / scale)
	}
}
