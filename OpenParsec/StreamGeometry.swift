import Foundation

enum StreamDisplayMode: Int {
	case adaptive = 0
	case original = 1
}

struct AdaptiveHostResolution: Equatable {
	let width: Int
	let height: Int

	static func target(for viewportSize: CGSize, nativeScale: CGFloat) -> AdaptiveHostResolution? {
		guard viewportSize.width > viewportSize.height,
			  viewportSize.width > 0, viewportSize.height > 0, nativeScale > 0 else { return nil }
		let screenWidth = Int((viewportSize.width * nativeScale).rounded())
		let screenHeight = Int((viewportSize.height * nativeScale).rounded())
		guard screenWidth > screenHeight else { return nil }

		let maxWidth = 3840
		let maxHeight = 2160
		let scale = min(1.0, min(Double(maxWidth) / Double(screenWidth),
							 Double(maxHeight) / Double(screenHeight)))
		let width = nearestEven(Double(screenWidth) * scale)
		let height = nearestEven(Double(screenHeight) * scale)
		guard width >= 640, height >= 360 else { return nil }
		return AdaptiveHostResolution(width: width, height: height)
	}

	static func nearestEven(_ value: Double) -> Int {
		guard value.isFinite else { return 0 }
		return max(0, 2 * Int((value / 2).rounded()))
	}
}

struct StreamGeometry {
	let viewportSize: CGSize
	let hostSize: CGSize

	var validSize: Bool {
		hostSize.width > 0 && hostSize.height > 0 &&
		viewportSize.width > 0 && viewportSize.height > 0
	}

	var scale: CGFloat {
		guard validSize else { return 1 }
		return min(viewportSize.width / hostSize.width, viewportSize.height / hostSize.height)
	}

	var pictureSize: CGSize {
		guard validSize else { return viewportSize }
		return CGSize(width: hostSize.width * scale, height: hostSize.height * scale)
	}

	var contentSize: CGSize { pictureSize }

	var contentOffset: CGPoint {
		CGPoint(x: (viewportSize.width - pictureSize.width) / 2,
				y: (viewportSize.height - pictureSize.height) / 2)
	}

	var pictureOrigin: CGPoint {
		CGPoint(x: max(0, contentOffset.x), y: max(0, contentOffset.y))
	}

	var pictureRect: CGRect {
		CGRect(origin: pictureOrigin, size: pictureSize)
	}

	func screenPoint(forHostPoint point: CGPoint) -> CGPoint {
		CGPoint(x: pictureOrigin.x + point.x * scale,
				y: pictureOrigin.y + point.y * scale)
	}

	func hostPoint(forScreenPoint point: CGPoint) -> CGPoint {
		guard scale > 0 else { return .zero }
		return CGPoint(x: (point.x - pictureOrigin.x) / scale,
					   y: (point.y - pictureOrigin.y) / scale)
	}

	func sdkPoint(forViewportPoint point: CGPoint, sdkHostSize: CGSize) -> CGPoint {
		guard validSize, sdkHostSize.width > 0, sdkHostSize.height > 0 else {
			return CGPoint(x: min(max(0, point.x), viewportSize.width),
						   y: min(max(0, point.y), viewportSize.height))
		}
		let hostPoint = hostPoint(forScreenPoint: point)
		let hostFractionX = min(max(0, hostPoint.x / hostSize.width), 1)
		let hostFractionY = min(max(0, hostPoint.y / hostSize.height), 1)
		let sdkGeometry = StreamGeometry(viewportSize: viewportSize, hostSize: sdkHostSize)
		return sdkGeometry.screenPoint(forHostPoint: CGPoint(
			x: hostFractionX * sdkHostSize.width,
			y: hostFractionY * sdkHostSize.height
		))
	}

	func viewportPoint(forSDKPoint point: CGPoint, sdkHostSize: CGSize) -> CGPoint {
		guard validSize, sdkHostSize.width > 0, sdkHostSize.height > 0 else {
			return CGPoint(x: min(max(0, point.x), viewportSize.width),
						   y: min(max(0, point.y), viewportSize.height))
		}
		let sdkGeometry = StreamGeometry(viewportSize: viewportSize, hostSize: sdkHostSize)
		let sdkHostPoint = sdkGeometry.hostPoint(forScreenPoint: point)
		let hostFractionX = min(max(0, sdkHostPoint.x / sdkHostSize.width), 1)
		let hostFractionY = min(max(0, sdkHostPoint.y / sdkHostSize.height), 1)
		return screenPoint(forHostPoint: CGPoint(
			x: hostFractionX * hostSize.width,
			y: hostFractionY * hostSize.height
		))
	}

	func visibleHostRect(zoomScale: CGFloat = 1, contentOffset: CGPoint = .zero) -> CGRect {
		guard validSize, zoomScale > 0 else { return CGRect(origin: .zero, size: hostSize) }
		let visibleOrigin = hostPoint(forScreenPoint: CGPoint(x: contentOffset.x / zoomScale, y: contentOffset.y / zoomScale))
		let visibleSize = CGSize(
			width: viewportSize.width / (scale * zoomScale),
			height: viewportSize.height / (scale * zoomScale)
		)
		return CGRect(origin: visibleOrigin, size: visibleSize)
			.intersection(CGRect(origin: .zero, size: hostSize))
	}
}

struct StreamPixelSize: Equatable {
	let width: Int
	let height: Int

	init(width: Int, height: Int) {
		self.width = max(0, width)
		self.height = max(0, height)
	}

	init(_ size: CGSize) {
		self.init(width: Int(size.width.rounded()), height: Int(size.height.rounded()))
	}

	var isValid: Bool { width > 0 && height > 0 }

	var size: CGSize { CGSize(width: width, height: height) }

	var aspectRatio: Double {
		guard isValid else { return 0 }
		return Double(width) / Double(height)
	}

	func matches(_ other: StreamPixelSize, tolerance: Double = 0.005) -> Bool {
		guard isValid, other.isValid, tolerance >= 0 else { return false }
		guard abs(width - other.width) <= 1 && abs(height - other.height) <= 1 else {
			guard aspectRatio > 0, other.aspectRatio > 0 else { return false }
			return abs(aspectRatio - other.aspectRatio) / other.aspectRatio < tolerance
		}
		return true
	}
}

enum AdaptiveRequestState: Equatable {
	case inactive
	case waiting(AdaptiveHostResolution, requestedAt: TimeInterval)
	case matched(AdaptiveHostResolution)
	case unmatched(AdaptiveHostResolution)

	var target: AdaptiveHostResolution? {
		switch self {
		case .inactive:
			return nil
		case .waiting(let target, _), .matched(let target), .unmatched(let target):
			return target
		}
	}

	var isWaiting: Bool {
		if case .waiting = self { return true }
		return false
	}

	var requestedAt: TimeInterval? {
		if case .waiting(_, let requestedAt) = self { return requestedAt }
		return nil
	}
}

struct AdaptiveResolutionRequestTracker: Equatable {
	let target: AdaptiveHostResolution
	let requestedAt: TimeInterval
	var timedOut: Bool = false

	static func accepts(frame: StreamPixelSize, target: AdaptiveHostResolution) -> Bool {
		frame.matches(StreamPixelSize(width: target.width, height: target.height))
	}

	mutating func observe(frame: StreamPixelSize, now: TimeInterval, timeout: TimeInterval) -> AdaptiveRequestState {
		if Self.accepts(frame: frame, target: target) {
			timedOut = false
			return .matched(target)
		}
		if !timedOut && now - requestedAt >= timeout {
			timedOut = true
			return .unmatched(target)
		}
		return timedOut ? .unmatched(target) : .waiting(target, requestedAt: requestedAt)
	}
}
