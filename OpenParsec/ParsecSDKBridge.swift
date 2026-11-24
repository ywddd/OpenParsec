import ParsecSDK
import MetalKit
import UIKit
import os

let sdkLog = OSLog(subsystem: "com.aigch.OpenParsec", category: "sdk")
let appLog = OSLog(subsystem: "com.aigch.OpenParsec", category: "app")

final class ConnectionLog: ObservableObject {
	static let shared = ConnectionLog()

	private struct Entry {
		var time: String
		let text: String
		var count: Int
	}

	@Published private(set) var lines: [String] = []
	private var entries: [Entry] = []
	private let lock = NSLock()
	private var pending: [(time: String, text: String)] = []
	private var flushScheduled = false
	private let clock: DateFormatter = {
		let f = DateFormatter()
		f.dateFormat = "HH:mm:ss.S"
		return f
	}()

	func add(_ text: String) {
		let time = clock.string(from: Date())
		lock.lock()
		pending.append((time, text))
		let schedule = !flushScheduled
		flushScheduled = true
		lock.unlock()
		if schedule {
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.flush() }
		}
	}

	private func flush() {
		lock.lock()
		let fresh = pending
		pending.removeAll()
		flushScheduled = false
		lock.unlock()
		for item in fresh {
			if let last = entries.indices.last, entries[last].text == item.text {
				entries[last].count += 1
				entries[last].time = item.time
			} else {
				entries.append(Entry(time: item.time, text: item.text, count: 1))
			}
		}
		if entries.count > 200 {
			entries.removeFirst(entries.count - 200)
		}
		lines = entries.map { "\($0.time) \($0.text)\($0.count > 1 ? " x\($0.count)" : "")" }
	}
}

func appNote(_ text: String) {
	os_log("%{public}@", log: appLog, text)
	ConnectionLog.shared.add(text)
}

enum RendererType: Int {
	case opengl
    case metal
}

enum DecoderPref: Int {
    case h264
    case h265
}

enum CursorMode: Int {
    case touchpad
    case direct
}

enum RightClickPosition: Int {
	case firstFinger
	case middle
	case secondFinger
}

enum MenuSwipeEdge: Int {
	case left
	case right
	case off
}

private final class ParsecFramePollContext {
	let bridge: ParsecSDKBridge
	let callback: ParsecFrameCallback
	let opaque: UnsafeRawPointer
	let generation: Int

	init(bridge: ParsecSDKBridge, callback: @escaping ParsecFrameCallback, opaque: UnsafeRawPointer, generation: Int) {
		self.bridge = bridge
		self.callback = callback
		self.opaque = opaque
		self.generation = generation
	}
}

struct KeyBoardKeyEvent {
	var input: UIKey?
	var isPressBegin: Bool
}

class ParsecSDKBridge: ParsecService {
	var hostWidth: Float = 1920

	var hostHeight: Float = 1080

	var sdkHostSize: CGSize {
		CGSize(width: CGFloat(hostWidth), height: CGFloat(hostHeight))
	}

	var actualHostSize: CGSize {
		actualFrameLock.lock()
		let size = lastActualFrameSize
		actualFrameLock.unlock()
		return size.isValid ? size.size : sdkHostSize
	}

	static let PARSEC_VER: UInt32 = UInt32((PARSEC_VER_MAJOR << 16) | PARSEC_VER_MINOR)

	private var _parsec: OpaquePointer!
	private var _audio: OpaquePointer!
	private let _audioPtr: UnsafeRawPointer

	private var isVirtualShiftOn = false

	public var clientWidth: Float = 1920
	public var clientHeight: Float = 1080
	var displayMode: StreamDisplayMode = SettingsHandler.streamDisplayMode
	private var hasFrame = false
	private var didSetDimensions = false
	private var lastActualFrameSize = StreamPixelSize(width: 0, height: 0)
	private var pendingActualFrameSize: StreamPixelSize?
	private var pendingActualFrameGeneration = 0
	private let actualFrameLock = NSLock()
	private var requestTimeoutWorkItem: DispatchWorkItem?
	private var actualFrameDeliveryScheduled = false
	private var actualFrameDeliveryToken = 0
	private var lastDeliveredActualFrameSize = StreamPixelSize(width: 0, height: 0)
	static let adaptiveRequestTimeout: TimeInterval = 10

	public var netProtocol: Int32 = 1
	public var mediaContainer: Int32 = 0
	public var pngCursor: Bool = false
	private let generationLock = NSLock()
	private var currentGeneration = 0
	private var pollGeneration: Int {
		get {
			generationLock.lock()
			defer { generationLock.unlock() }
			return currentGeneration
		}
		set {
			generationLock.lock()
			currentGeneration = newValue
			generationLock.unlock()
		}
	}
	var didSetResolution = false
	private var didReleaseOnConnect = false
	private var capsLock = false

	public var mouseInfo = MouseInfo()
	// when we last told the host where to put the cursor
	private var lastMoveSent: CFTimeInterval = 0
	private var dimsSetAt: CFTimeInterval = 0

	init() {
		os_log("%{public}@", log: sdkLog, "Parsec SDK Version: " + String(ParsecSDKBridge.PARSEC_VER))
		let runtimeVer = ParsecVersion()
		os_log("%{public}@", log: sdkLog, "Parsec SDK binary: \(runtimeVer >> 16).\(runtimeVer & 0xFFFF)")

		ParsecSetLogCallback(
			{ (level, msg, _) in
				guard let msg = msg else { return }
				let line = "[\(level == LOG_DEBUG ? "D" : "I")] \(String(cString: msg))"
				os_log("%{public}@", log: sdkLog, type: level == LOG_DEBUG ? .info : .default, line)
				ConnectionLog.shared.add("sdk \(line)")
				if line.contains("signal_") && line.contains("] = -") {
					let at = Date()
					DispatchQueue.main.async { CParsec.setupError = (line, at) }
				}
			}, nil)

		audio_init(&_audio)

		self._audioPtr = UnsafeRawPointer(_audio)

		do {
			let reservedCfg = ["ssHost": "kessel-ws.parsec.app"]
			let json = JSONEncoder()
			var jsonData = try json.encode(reservedCfg)
			jsonData.append(0)
			jsonData.withUnsafeBytes { (jsonStrBPtr: UnsafeRawBufferPointer) in
				guard let jsonStrPtr = jsonStrBPtr.baseAddress else {
					return
				}
				ParsecInit(ParsecSDKBridge.PARSEC_VER, nil, jsonStrPtr, &_parsec)
			}

		} catch {
			print("error: \(error)")
		}

	}

	deinit {
		ParsecDestroy(_parsec)
		audio_destroy(&_audio)
	}

	private func captureFrameSize(width: Int, height: Int, generation: Int) {
		let size = StreamPixelSize(width: width, height: height)
		guard size.isValid else { return }
		actualFrameLock.lock()
		if generation == pollGeneration {
			pendingActualFrameSize = size
			pendingActualFrameGeneration = generation
		}
		actualFrameLock.unlock()
	}

	private func captureFrameSize(_ frame: ParsecFrame, generation: Int) {
		captureFrameSize(width: Int(frame.width), height: Int(frame.height), generation: generation)
	}

	private func publishPendingActualFrameSize() {
		actualFrameLock.lock()
		let size = pendingActualFrameSize
		let generation = pendingActualFrameGeneration
		pendingActualFrameSize = nil
		actualFrameLock.unlock()
		guard let size = size, generation == pollGeneration else { return }
		deliverActualFrameSize(size, generation: generation)
	}

	private func deliverActualFrameSize(_ size: StreamPixelSize, generation: Int) {
		actualFrameLock.lock()
		guard generation == pollGeneration else {
			actualFrameLock.unlock()
			return
		}
		let changed = size != lastActualFrameSize
		if changed { lastActualFrameSize = size }
		var scheduledToken: Int?
		if changed && !actualFrameDeliveryScheduled {
			actualFrameDeliveryScheduled = true
			actualFrameDeliveryToken &+= 1
			scheduledToken = actualFrameDeliveryToken
		}
		actualFrameLock.unlock()
		if let scheduledToken = scheduledToken {
			DispatchQueue.main.async { [weak self] in
				self?.flushActualFrameDelivery(generation: generation, token: scheduledToken)
			}
		}
	}

	private func flushActualFrameDelivery(generation: Int, token: Int) {
		actualFrameLock.lock()
		guard actualFrameDeliveryScheduled, actualFrameDeliveryToken == token else {
			actualFrameLock.unlock()
			return
		}
		actualFrameDeliveryScheduled = false
		guard generation == pollGeneration else {
			actualFrameLock.unlock()
			return
		}
		let size = lastActualFrameSize
		let changed = size != lastDeliveredActualFrameSize
		if changed { lastDeliveredActualFrameSize = size }
		actualFrameLock.unlock()
		guard changed, size.isValid else { return }
		DataManager.model.actualFrameWidth = size.width
		DataManager.model.actualFrameHeight = size.height
		observeAdaptiveFrame(size)
	}

	private func publishDecoderSize(width: Int, height: Int) {
		let generation = pollGeneration
		DispatchQueue.main.async {
			guard generation == self.pollGeneration else { return }
			if DataManager.model.decoderWidth != width || DataManager.model.decoderHeight != height {
				DataManager.model.decoderWidth = width
				DataManager.model.decoderHeight = height
			}
		}
	}

	private func resetActualFrameSize() {
		actualFrameLock.lock()
		pendingActualFrameSize = nil
		pendingActualFrameGeneration = 0
		lastActualFrameSize = StreamPixelSize(width: 0, height: 0)
		actualFrameDeliveryScheduled = false
		actualFrameDeliveryToken &+= 1
		lastDeliveredActualFrameSize = StreamPixelSize(width: 0, height: 0)
		actualFrameLock.unlock()
		DataManager.model.actualFrameWidth = 0
		DataManager.model.actualFrameHeight = 0
	}

	private func recordAdaptiveRequest(_ target: AdaptiveHostResolution, hostVideoConfig: Bool = false) {
		let now = CACurrentMediaTime()
		DataManager.model.adaptiveResolution = target
		DataManager.model.adaptiveRequestState = .waiting(target, requestedAt: now)
		DataManager.model.requestedResolutionX = target.width
		DataManager.model.requestedResolutionY = target.height
		if hostVideoConfig {
			updateHostVideoConfig()
		}
		scheduleAdaptiveRequestTimeout(target: target, at: now)
	}

	static func currentViewportSize(preferring size: CGSize) -> CGSize {
		if size.width > 0, size.height > 0 { return size }
		let window = UIApplication.shared.connectedScenes
			.compactMap { $0 as? UIWindowScene }
			.flatMap { $0.windows }
			.first { $0.isKeyWindow }
		return window?.bounds.size ?? UIScreen.main.bounds.size
	}

	func requestAdaptiveResolution(_ target: AdaptiveHostResolution) {
		guard displayMode == .adaptive,
			  !DataManager.model.adaptiveResolutionPaused,
			  SettingsHandler.resolution == .client else { return }
		if DataManager.model.adaptiveRequestState.target == target { return }
		recordAdaptiveRequest(target, hostVideoConfig: true)
	}

	func resetAdaptiveResolutionRequest() {
		cancelAdaptiveRequestTimer()
		DataManager.model.adaptiveResolution = nil
		DataManager.model.adaptiveRequestState = .inactive
		DataManager.model.requestedResolutionX = 0
		DataManager.model.requestedResolutionY = 0
	}

	private func scheduleAdaptiveRequestTimeout(target: AdaptiveHostResolution, at requestedAt: TimeInterval) {
		requestTimeoutWorkItem?.cancel()
		let generation = pollGeneration
		let work = DispatchWorkItem { [weak self] in
			guard let self = self, generation == self.pollGeneration,
				  self.displayMode == .adaptive, !DataManager.model.adaptiveResolutionPaused else { return }
			let state = DataManager.model.adaptiveRequestState
			guard case .waiting(let waitingTarget, let waitingAt) = state,
				  waitingTarget == target, waitingAt == requestedAt else { return }
			let actual = StreamPixelSize(
				width: DataManager.model.actualFrameWidth,
				height: DataManager.model.actualFrameHeight
			)
			if AdaptiveResolutionRequestTracker.accepts(frame: actual, target: target) {
				DataManager.model.adaptiveRequestState = .matched(target)
				return
			}
			DataManager.model.adaptiveRequestState = .unmatched(target)
			appNote("[adaptive] host did not adopt \(target.width)x\(target.height); actual \(actual.width)x\(actual.height), network latency is not proof of rejection")
		}
		requestTimeoutWorkItem = work
		DispatchQueue.main.asyncAfter(deadline: .now() + Self.adaptiveRequestTimeout, execute: work)
	}

	private func cancelAdaptiveRequestTimer() {
		requestTimeoutWorkItem?.cancel()
		requestTimeoutWorkItem = nil
	}

	private func observeAdaptiveFrame(_ size: StreamPixelSize) {
		let state = DataManager.model.adaptiveRequestState
		guard let target = state.target,
			  !DataManager.model.adaptiveResolutionPaused,
			  SettingsHandler.resolution == .client,
			  displayMode == .adaptive else { return }
		let now = CACurrentMediaTime()
		switch state {
		case .waiting(_, let requestedAt):
			var tracker = AdaptiveResolutionRequestTracker(target: target, requestedAt: requestedAt)
			let next = tracker.observe(frame: size, now: now, timeout: Self.adaptiveRequestTimeout)
			guard next != state else { return }
			if !next.isWaiting { cancelAdaptiveRequestTimer() }
			DataManager.model.adaptiveRequestState = next
		case .matched:
			guard !AdaptiveResolutionRequestTracker.accepts(frame: size, target: target) else { return }
			DataManager.model.adaptiveRequestState = .waiting(target, requestedAt: now)
			scheduleAdaptiveRequestTimeout(target: target, at: now)
		case .unmatched:
			guard AdaptiveResolutionRequestTracker.accepts(frame: size, target: target) else { return }
			cancelAdaptiveRequestTimer()
			DataManager.model.adaptiveRequestState = .matched(target)
		case .inactive:
			break
		}
	}

	var adaptiveDiagnostic: String {
		let state = DataManager.model.adaptiveRequestState
		switch state {
		case .inactive:
			return "自适应：关闭"
		case .waiting(let target, _):
			return "自适应：等待 \(target.width)×\(target.height)"
		case .matched(let target):
			return "自适应：已匹配 \(target.width)×\(target.height)"
		case .unmatched(let target):
			return "自适应：未匹配 \(target.width)×\(target.height)"
		}
	}

	private func publishViewportGeometry(_ geometry: StreamGeometry) {
		let generation = pollGeneration
		let viewport = StreamPixelSize(geometry.viewportSize)
		let picture = StreamPixelSize(geometry.pictureSize)
		let origin = geometry.pictureOrigin
		DispatchQueue.main.async {
			guard generation == self.pollGeneration else { return }
			guard DataManager.model.viewportWidth != viewport.width ||
				  DataManager.model.viewportHeight != viewport.height ||
				  DataManager.model.pictureWidth != picture.width ||
				  DataManager.model.pictureHeight != picture.height ||
				  DataManager.model.pictureX != Int(origin.x.rounded()) ||
				  DataManager.model.pictureY != Int(origin.y.rounded()) else { return }
			DataManager.model.viewportWidth = viewport.width
			DataManager.model.viewportHeight = viewport.height
			DataManager.model.pictureWidth = picture.width
			DataManager.model.pictureHeight = picture.height
			DataManager.model.pictureX = Int(origin.x.rounded())
			DataManager.model.pictureY = Int(origin.y.rounded())
		}
	}

	private func clientVideoSize() -> StreamPixelSize {
		if displayMode == .adaptive,
		   !DataManager.model.adaptiveResolutionPaused,
		   SettingsHandler.resolution == .client,
		   let target = AdaptiveHostResolution.target(
			for: ParsecSDKBridge.currentViewportSize(preferring: .zero),
			nativeScale: UIScreen.main.nativeScale) {
			return StreamPixelSize(width: target.width, height: target.height)
		}
		let settings = SettingsHandler.resolution
		if settings == .client { return StreamPixelSize(width: 0, height: 0) }
		return StreamPixelSize(width: settings.width, height: settings.height)
	}

	func connect(_ peerID: String) -> ParsecStatus {

		var parsecClientCfg = ParsecClientConfig()
		parsecClientCfg.video.0.decoderIndex = 1
		let initialResolution = clientVideoSize()
		parsecClientCfg.video.0.resolutionX = Int32(initialResolution.width)
		parsecClientCfg.video.0.resolutionY = Int32(initialResolution.height)
		parsecClientCfg.video.0.decoderH265 = SettingsHandler.decoder == .h265

		parsecClientCfg.video.1.decoderIndex = 1
		parsecClientCfg.video.1.resolutionX = Int32(initialResolution.width)
		parsecClientCfg.video.1.resolutionY = Int32(initialResolution.height)
		parsecClientCfg.video.1.decoderH265 = SettingsHandler.decoder == .h265

		parsecClientCfg.mediaContainer = 0
		parsecClientCfg.protocol = 1
		// parsecClientCfg.secret = ""
		parsecClientCfg.pngCursor = false

		self.startBackgroundTask()
		didReleaseOnConnect = false
		didSetDimensions = false
		didSetResolution = false
		hasFrame = false
		resetAdaptiveResolutionRequest()
		resetActualFrameSize()

		let status = ParsecClientConnect(_parsec, &parsecClientCfg, NetworkHandler.clinfo?.session_id, peerID)

		if status == PARSEC_OK || status == PARSEC_CONNECTING {
			if self.displayMode == .adaptive,
			   !DataManager.model.adaptiveResolutionPaused,
			   SettingsHandler.resolution == .client,
			   let target = AdaptiveHostResolution.target(
				for: ParsecSDKBridge.currentViewportSize(preferring: .zero),
				nativeScale: UIScreen.main.nativeScale) {
				recordAdaptiveRequest(target)
			}
			ParsecBackgroundManager.shared.connectionDidStart()
		}

		return status
	}

	func disconnect() {

		pollGeneration += 1
		cancelAdaptiveRequestTimer()
		resetActualFrameSize()
		let generation = pollGeneration
		DispatchQueue.main.async {
			guard generation == self.pollGeneration else { return }
			DataManager.model.adaptiveRequestState = .inactive
			DataManager.model.adaptiveResolution = nil
			DataManager.model.requestedResolutionX = 0
			DataManager.model.requestedResolutionY = 0
		}
		// must go before the disconnect, after it the release never reaches the host
		sendReleaseMessage()
		ParsecClientDisconnect(_parsec)
		audio_clear(&_audio)

		ParsecBackgroundManager.shared.connectionDidEnd()
	}

	func reconnect(_ peerID: String) -> ParsecStatus {
		resetAdaptiveResolutionRequest()
		sendReleaseMessage()
		pollGeneration += 1
		cancelAdaptiveRequestTimer()
		resetActualFrameSize()
		didSetResolution = false
		ParsecClientDisconnect(_parsec)
		audio_clear(&_audio)
		audio_hold(false, _audioPtr)
		ParsecBackgroundManager.shared.connectionDidEnd()
		let status = connect(peerID)
		if status != PARSEC_OK && status != PARSEC_CONNECTING {
			ParsecBackgroundManager.shared.connectionDidEnd()
		}
		return status
	}

	func sendReleaseMessage() {
		var msg = ParsecMessage()
		msg.type = MESSAGE_RELEASE
		ParsecClientSendMessage(_parsec, &msg)
		isVirtualShiftOn = false
		DispatchQueue.main.async {
			NotificationCenter.default.post(name: NSNotification.Name("ParsecInputReleased"), object: nil)
		}
	}

	@discardableResult
	func pause(video: Bool = true, audio: Bool = true) -> ParsecStatus {
		let status = ParsecClientPause(_parsec, video, audio)
		if audio {
			audio_hold(true, _audioPtr)
		}
		return status
	}

	@discardableResult
	func resume() -> ParsecStatus {
		audio_hold(false, _audioPtr)
		return ParsecClientPause(_parsec, false, false)
	}

	func getStatus() -> ParsecStatus {

		return ParsecClientGetStatus(_parsec, nil)
	}

	func getStatusEx(_ pcs: inout ParsecClientStatus) -> ParsecStatus {
		let ans = ParsecClientGetStatus(_parsec, &pcs)
		let decoderWidth = Int(pcs.decoder.0.width)
		let decoderHeight = Int(pcs.decoder.0.height)
		if decoderWidth > 0 && decoderHeight > 0 {
			let oldSize = sdkHostSize
			let newSize = CGSize(width: CGFloat(decoderWidth), height: CGFloat(decoderHeight))
			if oldSize != newSize {
				let viewportSize = CGSize(width: CGFloat(clientWidth), height: CGFloat(clientHeight))
				if oldSize.width > 0, oldSize.height > 0,
				   viewportSize.width > 0, viewportSize.height > 0 {
					let oldGeometry = StreamGeometry(viewportSize: viewportSize, hostSize: oldSize)
					let newGeometry = StreamGeometry(viewportSize: viewportSize, hostSize: newSize)
					let hostPoint = oldGeometry.hostPoint(forScreenPoint: CGPoint(
						x: CGFloat(mouseInfo.mouseX),
						y: CGFloat(mouseInfo.mouseY)
					))
					let moved = newGeometry.screenPoint(forHostPoint: CGPoint(
						x: min(max(0, hostPoint.x / oldSize.width), 1) * newSize.width,
						y: min(max(0, hostPoint.y / oldSize.height), 1) * newSize.height
					))
					mouseInfo.mouseX = ParsecSDKBridge.clamp(Int32(moved.x.rounded()), minValue: 0, maxValue: Int32(clientWidth))
					mouseInfo.mouseY = ParsecSDKBridge.clamp(Int32(moved.y.rounded()), minValue: 0, maxValue: Int32(clientHeight))
				}
				self.hostWidth = Float(decoderWidth)
				self.hostHeight = Float(decoderHeight)
			}
			publishDecoderSize(width: decoderWidth, height: decoderHeight)
		}
		publishPendingActualFrameSize()

		// the teardown release may not have made it out, this one goes over a socket we know is live
		if ans == PARSEC_OK && !didReleaseOnConnect {
			didReleaseOnConnect = true
			sendReleaseMessage()
		}

		return ans
	}

	func setFrame(_ width: CGFloat, _ height: CGFloat, _ scale: CGFloat) {

		ParsecClientSetDimensions(_parsec, UInt8(DEFAULT_STREAM), UInt32(width), UInt32(height), Float(scale))
		publishViewportGeometry(StreamGeometry(
			viewportSize: CGSize(width: width, height: height),
			hostSize: CGSize(width: CGFloat(CParsec.actualFrameWidth), height: CGFloat(CParsec.actualFrameHeight))
		))
		if !didSetDimensions { dimsSetAt = CACurrentMediaTime() }
		didSetDimensions = true

		let oldSize = CGSize(width: CGFloat(clientWidth), height: CGFloat(clientHeight))
		let oldSDKPoint = CGPoint(x: CGFloat(mouseInfo.mouseX), y: CGFloat(mouseInfo.mouseY))
		let oldGeometry = StreamGeometry(viewportSize: oldSize, hostSize: sdkHostSize)
		clientWidth = Float(width)
		clientHeight = Float(height)
		guard hasFrame, oldSize.width > 0, oldSize.height > 0 else {
			hasFrame = true
			mouseInfo.mouseX = Int32(width / 2)
			mouseInfo.mouseY = Int32(height / 2)
			return
		}
		let sdkHostPoint = oldGeometry.hostPoint(forScreenPoint: oldSDKPoint)
		let newGeometry = StreamGeometry(viewportSize: CGSize(width: width, height: height), hostSize: sdkHostSize)
		let moved = newGeometry.screenPoint(forHostPoint: sdkHostPoint)
		mouseInfo.mouseX = ParsecSDKBridge.clamp(Int32(moved.x.rounded()), minValue: 0, maxValue: Int32(width))
		mouseInfo.mouseY = ParsecSDKBridge.clamp(Int32(moved.y.rounded()), minValue: 0, maxValue: Int32(height))
	}

	// timeout in ms, 16 == 60 FPS, 8 == 120 FPS, etc.
	func renderGLFrame(timeout: UInt32 = 16, preRender: ParsecPreRenderCallback? = nil, opaque: UnsafeRawPointer? = nil) {
		ParsecClientGLRenderFrame(_parsec, UInt8(DEFAULT_STREAM), preRender, opaque, timeout)
	}

	func glDestroy() {
		ParsecClientGLDestroy(_parsec, UInt8(DEFAULT_STREAM))
	}

	func pollFrame(timeout: UInt32, callback: ParsecFrameCallback, opaque: UnsafeRawPointer) -> ParsecStatus {
		let generation = pollGeneration
		let holder = ParsecFramePollContext(bridge: self, callback: callback, opaque: opaque, generation: generation)
		let status = withExtendedLifetime(holder) {
			ParsecClientPollFrame(_parsec, UInt8(DEFAULT_STREAM), { frame, image, context in
				guard let frame = frame, image != nil, let context = context else { return }
				let holder = Unmanaged<ParsecFramePollContext>.fromOpaque(context).takeUnretainedValue()
				guard holder.generation == holder.bridge.pollGeneration else { return }
				guard frame.pointee.isWholeNV12 else { return }
				holder.bridge.captureFrameSize(frame.pointee, generation: holder.generation)
				if holder.generation == holder.bridge.pollGeneration {
					holder.callback(frame, image, holder.opaque)
				}
			}, timeout, Unmanaged.passUnretained(holder).toOpaque())
		}
		if generation == pollGeneration {
			publishPendingActualFrameSize()
		}
		return status
	}

	@discardableResult
	func pollAudio(timeout: UInt32 = 16) -> ParsecStatus { // timeout in ms, 16 == 60 FPS, 8 == 120 FPS, etc.
		return ParsecClientPollAudio(_parsec, audio_cb, timeout, _audioPtr)
	}

	var mousePositionRelative = false

	@discardableResult
	func pollEvent(timeout: UInt32 = 16, sawCursor: inout Bool) -> Bool { // timeout in ms, 16 == 60 FPS, 8 == 120 FPS, etc.
		let generation = pollGeneration
		var e: ParsecClientEvent!
		var _event = ParsecClientEvent()
		var pollSuccess = false
		withUnsafeMutablePointer(to: &_event, {(_eventPtr) in
			pollSuccess = ParsecClientPollEvents(_parsec, timeout, _eventPtr)
			e = _eventPtr.pointee
		})
		guard generation == pollGeneration else { return false }
		if !pollSuccess {
			return ParsecClientGetStatus(_parsec, nil) != PARSEC_OK
		}
		if e.type == CLIENT_EVENT_CURSOR {
			handleCursorEvent(event: e.cursor, sawCursor: &sawCursor)
		} else if e.type == CLIENT_EVENT_USER_DATA {
			handleUserDataEvent(event: e.userData, generation: generation)
		} else if e.type == CLIENT_EVENT_STREAM {
			os_log("%{public}@", log: sdkLog, "[stream] s=\(e.stream.stream) status=\(e.stream.status.rawValue)")
		} else if e.type == CLIENT_EVENT_BLOCKED {
			DispatchQueue.main.async {
				guard generation == self.pollGeneration else { return }
				DataManager.model.isBlocked = true
			}
		} else if e.type == CLIENT_EVENT_UNBLOCKED {
			DispatchQueue.main.async {
				guard generation == self.pollGeneration else { return }
				DataManager.model.isBlocked = false
			}
		}
		return false
	}

	func handleUserDataEvent(event: ParsecClientUserDataEvent, generation: Int) {

		let pointer = ParsecGetBuffer(_parsec, event.key)
		if pointer == nil {
			return
		}
		switch event.id {
		case ParsecUserDataType.clipboard.rawValue:
			ClipboardSync.shared.receive(String(cString: pointer!.assumingMemoryBound(to: CChar.self)))
		case 11:
			do {
				let decoder = JSONDecoder()
				let config = try decoder.decode(ParsecUserDataVideoConfig.self, from: Data(bytesNoCopy: pointer!, count: strlen(pointer!), deallocator: .none))
				let videoConfig = config.video.first
				DispatchQueue.main.async {
					guard generation == self.pollGeneration else { return }
					if let cfg = videoConfig {
						DataManager.model.resolutionX = cfg.resolutionX
						DataManager.model.resolutionY = cfg.resolutionY
						DataManager.model.bitrate = cfg.encoderMaxBitrate
						DataManager.model.constantFps = cfg.fullFPS
					}
					if !self.didSetResolution {
						self.didSetResolution = true
						if DataManager.model.hostDefaultBitrate == 0 {
							DataManager.model.hostDefaultBitrate = DataManager.model.bitrate
						}
						if self.displayMode == .adaptive,
						   !DataManager.model.adaptiveResolutionPaused,
						   SettingsHandler.resolution == .client,
						   let target = DataManager.model.adaptiveResolution {
							DataManager.model.requestedResolutionX = target.width
							DataManager.model.requestedResolutionY = target.height
						} else {
							let settings = SettingsHandler.resolution
							DataManager.model.requestedResolutionX = settings == .client ? 0 : settings.width
							DataManager.model.requestedResolutionY = settings == .client ? 0 : settings.height
						}
						DataManager.model.constantFps = SettingsHandler.constantFps
						if SettingsHandler.bitrate > 0 {
							DataManager.model.bitrate = SettingsHandler.bitrate
						}
						self.updateHostVideoConfig()
					}
				}

			} catch {
				print("error while parsing user data: \(error.localizedDescription)")
			}
		case 12:
			do {
				let decoder = JSONDecoder()
				let config = try decoder.decode(Array<ParsecDisplayConfig>.self, from: Data(bytesNoCopy: pointer!, count: strlen(pointer!), deallocator: .none))
				DispatchQueue.main.async {
					guard generation == self.pollGeneration else { return }
					DataManager.model.displayConfigs = config
				}
			} catch {
				print("error while parsing user data: \(error.localizedDescription)")
			}
		default:
			break
		}

		ParsecFree(pointer)

	}

	func handleCursorEvent(event: ParsecClientCursorEvent, sawCursor: inout Bool) {
		let prevHidden = mouseInfo.cursorHidden
		let prevRelative = mouseInfo.mousePositionRelative
		mouseInfo.cursorHidden = event.cursor.hidden
		mouseInfo.mousePositionRelative = event.cursor.relative

		// cursor events are the only time the host tells us where its cursor is, so follow it, a mouse
		// on the host or another guest may have moved it. an event right after our own move is just
		// that move coming back, and before setFrame the sdk has no dims to scale the position with
		let isEcho = CACurrentMediaTime() - lastMoveSent < 0.3
		let settling = CACurrentMediaTime() - dimsSetAt < 1
		let viewportSize = CGSize(width: CGFloat(clientWidth), height: CGFloat(clientHeight))
		let sdkGeometry = StreamGeometry(viewportSize: viewportSize, hostSize: sdkHostSize)
		let origin = sdkGeometry.screenPoint(forHostPoint: .zero)
		let atOrigin = abs(Float(event.cursor.positionX) - Float(origin.x)) < 1 && abs(Float(event.cursor.positionY) - Float(origin.y)) < 1
		if didSetDimensions && !settling && !atOrigin && (prevHidden || prevRelative || !isEcho) && !event.cursor.relative && !event.cursor.hidden {
			mouseInfo.mouseX = ParsecSDKBridge.clamp(Int32(clamping: event.cursor.positionX), minValue: 0, maxValue: Int32(clientWidth))
			mouseInfo.mouseY = ParsecSDKBridge.clamp(Int32(clamping: event.cursor.positionY), minValue: 0, maxValue: Int32(clientHeight))
		}

		if event.cursor.imageUpdate || !sawCursor {
			sawCursor = true
			let imgKey = event.key
			let pointer = ParsecGetBuffer(_parsec, imgKey)
			if pointer == nil {
				return
			}
			let size = event.cursor.size
			let width = event.cursor.width
			let height = event.cursor.height
			guard width > 0, height > 0, Int(size) >= Int(width) * Int(height) * 4 else {
				ParsecFree(pointer)
				return
			}
			mouseInfo.cursorWidth = Int(width)
			mouseInfo.cursorHeight = Int(height)

			mouseInfo.cursorHotX = Int(event.cursor.hotX)
			mouseInfo.cursorHotY = Int(event.cursor.hotY)

			let elmentLength: Int = 4
			let render: CGColorRenderingIntent = CGColorRenderingIntent.defaultIntent
			let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
			let bitmapInfo: CGBitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
			if let providerRef = CGDataProvider(data: NSData(bytes: pointer, length: Int(size))),
				let cgimage = CGImage(width: Int(width), height: Int(height), bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: Int(width) * elmentLength, space: rgbColorSpace, bitmapInfo: bitmapInfo, provider: providerRef, decode: nil, shouldInterpolate: true, intent: render) {
				mouseInfo.cursorImg = cgimage
			}
			ParsecFree(pointer)
		}
	}

	func setMuted(_ muted: Bool) {
		audio_mute(muted, _audioPtr)
	}

	func applyConfig() {

		var parsecClientCfg = ParsecClientConfig()

		parsecClientCfg.video.0.decoderIndex = 1
		parsecClientCfg.video.0.resolutionX = 0
		parsecClientCfg.video.0.resolutionY = 0
		parsecClientCfg.video.0.decoderH265 = SettingsHandler.decoder == .h265

		parsecClientCfg.video.1.decoderIndex = 1
		parsecClientCfg.video.1.resolutionX = 0
		parsecClientCfg.video.1.resolutionY = 0
		parsecClientCfg.video.1.decoderH265 = SettingsHandler.decoder == .h265

		parsecClientCfg.mediaContainer = mediaContainer
		parsecClientCfg.protocol = netProtocol
		// parsecClientCfg.secret = ""
		parsecClientCfg.pngCursor = pngCursor

		ParsecClientSetConfig(_parsec, &parsecClientCfg)
	}

	func sendMouseMessage(_ button: ParsecMouseButton, _ x: Int32, _ y: Int32, _ pressed: Bool) {
		// Send the mouse position
		sendMousePosition(x, y)

		// Send the mouse button state
		var buttonMessage = ParsecMessage()
		buttonMessage.type = MESSAGE_MOUSE_BUTTON
		buttonMessage.mouseButton.button = button
		buttonMessage.mouseButton.pressed = pressed
		ParsecClientSendMessage(_parsec, &buttonMessage)
	}

	func sendMouseMessage(_ button: ParsecMouseButton, viewportPoint: CGPoint, _ pressed: Bool) {
		sendMousePosition(viewportPoint: viewportPoint)
		var buttonMessage = ParsecMessage()
		buttonMessage.type = MESSAGE_MOUSE_BUTTON
		buttonMessage.mouseButton.button = button
		buttonMessage.mouseButton.pressed = pressed
		ParsecClientSendMessage(_parsec, &buttonMessage)
	}

	func sendMouseClickMessage(_ button: ParsecMouseButton, _ pressed: Bool) {
		var buttonMessage = ParsecMessage()
		buttonMessage.type = MESSAGE_MOUSE_BUTTON
		buttonMessage.mouseButton.button = button
		buttonMessage.mouseButton.pressed = pressed
		ParsecClientSendMessage(_parsec, &buttonMessage)
	}

	func sendMouseDelta(_ dx: Int32, _ dy: Int32) {
		if mouseInfo.mousePositionRelative {
			sendMouseRelativeMove(dx, dy)
		} else {
			sendMousePosition(mouseInfo.mouseX + dx, mouseInfo.mouseY + dy)
		}

	}
	static func clamp<T>(_ value: T, minValue: T, maxValue: T) -> T where T: Comparable {
		return min(max(value, minValue), maxValue)
	}

	func sendMousePosition(_ x: Int32, _ y: Int32) {
		let sdkPoint = CGPoint(
			x: CGFloat(ParsecSDKBridge.clamp(x, minValue: 0, maxValue: Int32(self.clientWidth))),
			y: CGFloat(ParsecSDKBridge.clamp(y, minValue: 0, maxValue: Int32(self.clientHeight)))
		)
		mouseInfo.mouseX = Int32(sdkPoint.x)
		mouseInfo.mouseY = Int32(sdkPoint.y)
		sendSDKPoint(sdkPoint)
	}

	func sendMousePosition(viewportPoint: CGPoint) {
		let actualGeometry = StreamGeometry(
			viewportSize: CGSize(width: CGFloat(clientWidth), height: CGFloat(clientHeight)),
			hostSize: actualHostSize
		)
		let sdkPoint = actualGeometry.sdkPoint(
			forViewportPoint: viewportPoint,
			sdkHostSize: sdkHostSize
		)
		mouseInfo.mouseX = ParsecSDKBridge.clamp(Int32(sdkPoint.x.rounded()), minValue: 0, maxValue: Int32(self.clientWidth))
		mouseInfo.mouseY = ParsecSDKBridge.clamp(Int32(sdkPoint.y.rounded()), minValue: 0, maxValue: Int32(self.clientHeight))
		sendSDKPoint(sdkPoint)
	}

	private func sendSDKPoint(_ point: CGPoint) {
		lastMoveSent = CACurrentMediaTime()
		var motionMessage = ParsecMessage()
		motionMessage.type = MESSAGE_MOUSE_MOTION
		motionMessage.mouseMotion.x = ParsecSDKBridge.clamp(Int32(point.x.rounded()), minValue: 0, maxValue: Int32(clientWidth))
		motionMessage.mouseMotion.y = ParsecSDKBridge.clamp(Int32(point.y.rounded()), minValue: 0, maxValue: Int32(clientHeight))
		ParsecClientSendMessage(_parsec, &motionMessage)
	}

	func sendMouseRelativeMove(_ dx: Int32, _ dy: Int32) {
		var motionMessage = ParsecMessage()
		motionMessage.type = MESSAGE_MOUSE_MOTION
		motionMessage.mouseMotion.x = dx
		motionMessage.mouseMotion.y = dy
		motionMessage.mouseMotion.relative = true
		ParsecClientSendMessage(_parsec, &motionMessage)
	}

	func getKeyCodeByText(text: String) -> (ParsecKeycode?, Bool) {
		var keyCode: ParsecKeycode?
		var useShift = false
		if text.count == 1 {
			let char = Character(text)
			if char.isLetter || char.isNumber {
				keyCode = KeyCodeTranslators.parsecKeyCodeTranslator(text.uppercased())
				if char.isUppercase {
					useShift = true
				}
			} else if char.isNewline {
				keyCode = ParsecKeycode(40)
			} else if char.isWhitespace {
				keyCode = ParsecKeycode(44)
			} else {
				let (keycodeRaw, keyMod) = KeyCodeTranslators.getParsecKeycode(for: text)
				if keycodeRaw != -1 {
					keyCode = ParsecKeycode(UInt32(keycodeRaw))
					if keyMod {
						useShift = true
					}
				}
			}
		} else {
			keyCode = KeyCodeTranslators.parsecKeyCodeTranslator(text)
		}

		return (keyCode, useShift)
	}

	func sendVirtualKeyboardInput(text: String) {
		let (keyCode, useShift) = getKeyCodeByText(text: text)

		guard let keyCode else {
			return
		}
		var keyboardMessagePress = ParsecMessage()
		keyboardMessagePress.type = MESSAGE_KEYBOARD
		let sendShift = !isVirtualShiftOn && useShift
		if sendShift {
			keyboardMessagePress.keyboard = ParsecKeyboardMessage(code: KEY_LSHIFT, mod: MOD_NONE, pressed: true, __pad: (0, 0, 0))
			ParsecClientSendMessage(_parsec, &keyboardMessagePress)
		}
		keyboardMessagePress.keyboard = ParsecKeyboardMessage(code: keyCode, mod: MOD_NONE, pressed: true, __pad: (0, 0, 0))
		ParsecClientSendMessage(_parsec, &keyboardMessagePress)

		// add release delay in case some games ignore instant key release
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
			var release = ParsecMessage()
			release.type = MESSAGE_KEYBOARD
			release.keyboard = ParsecKeyboardMessage(code: keyCode, mod: MOD_NONE, pressed: false, __pad: (0, 0, 0))
			ParsecClientSendMessage(self._parsec, &release)
			if sendShift {
				release.keyboard = ParsecKeyboardMessage(code: KEY_LSHIFT, mod: MOD_NONE, pressed: false, __pad: (0, 0, 0))
				ParsecClientSendMessage(self._parsec, &release)
			}
		}
	}

	func sendVirtualKeyboardInput(text: String, isOn: Bool) {
		let (keyCode, _) = getKeyCodeByText(text: text)

		guard let keyCode else {
			return
		}

		if keyCode.rawValue == 225 {
			isVirtualShiftOn = isOn
		}

		var keyboardMessagePress = ParsecMessage()
		keyboardMessagePress.type = MESSAGE_KEYBOARD
		keyboardMessagePress.keyboard.pressed = isOn
		keyboardMessagePress.keyboard.code = keyCode
		ParsecClientSendMessage(_parsec, &keyboardMessagePress)

	}

	func sendKeyboardMessage(event: KeyBoardKeyEvent) {
		if event.input == nil {
			return
		}

		var keyboardMessagePress = ParsecMessage()
		keyboardMessagePress.type = MESSAGE_KEYBOARD
		keyboardMessagePress.keyboard.code = ParsecKeycode(UInt32(KeyCodeTranslators.uiKeyCodeToInt(key: event.input?.keyCode ?? UIKeyboardHIDUsage.keyboardErrorUndefined)))
		keyboardMessagePress.keyboard.pressed = event.isPressBegin
		capsLock = event.input?.modifierFlags.contains(.alphaShift) == true
		keyboardMessagePress.keyboard.mod = capsLock ? MOD_CAPS : MOD_NONE
		ParsecClientSendMessage(_parsec, &keyboardMessagePress)
	}

	func sendKeyboardMessage(keyCode: UInt32, pressed: Bool)
	{
		var keyboardMessagePress = ParsecMessage()
		keyboardMessagePress.type = MESSAGE_KEYBOARD
		keyboardMessagePress.keyboard.code = ParsecKeycode(keyCode)
		keyboardMessagePress.keyboard.pressed = pressed
		keyboardMessagePress.keyboard.mod = capsLock ? MOD_CAPS : MOD_NONE
		ParsecClientSendMessage(_parsec, &keyboardMessagePress)
	}
	
	func sendGameControllerButtonMessage(controllerId: UInt32, _ button:ParsecGamepadButton, pressed: Bool)
	{
		var pmsg = ParsecMessage()
		pmsg.type = MESSAGE_GAMEPAD_BUTTON
		pmsg.gamepadButton.id = controllerId
		pmsg.gamepadButton.button = button
		pmsg.gamepadButton.pressed = pressed
		ParsecClientSendMessage(_parsec, &pmsg)
	}

	/*static func sendGameControllerTriggerButtonMessage(controllerId: UInt32, _ button:ParsecGamepadAxis, pressed: Bool)
	{
	    var pmsg = ParsecMessage()
		pmsg.type = MESSAGE_GAMEPAD_AXIS
		pmsg.gamepadAxis.id = controllerId
		pmsg.gamepadAxis.button = button
		pmsg.gamepadAxis.pressed = pressed
		ParsecClientSendMessage(_parsec, &pmsg)
	}*/

	func sendGameControllerAxisMessage(controllerId: UInt32, _ button: ParsecGamepadAxis, _ value: Int16) {
	    var pmsg = ParsecMessage()
		pmsg.type = MESSAGE_GAMEPAD_AXIS
		pmsg.gamepadAxis.id = controllerId
		pmsg.gamepadAxis.axis = button
		pmsg.gamepadAxis.value = value
		ParsecClientSendMessage(_parsec, &pmsg)
	}

	func sendGameControllerUnplugMessage(controllerId: UInt32) {
	    var pmsg = ParsecMessage()
		pmsg.type = MESSAGE_GAMEPAD_UNPLUG
		pmsg.gamepadUnplug.id = controllerId
		ParsecClientSendMessage(_parsec, &pmsg)
	}

	func sendWheelMsg(x: Int32, y: Int32) {
		var pmsg = ParsecMessage()
		pmsg.type = MESSAGE_MOUSE_WHEEL
		pmsg.mouseWheel.x = x
		pmsg.mouseWheel.y = y
		ParsecClientSendMessage(_parsec, &pmsg)
	}

	func startBackgroundTask() {

		pollGeneration += 1
		let generation = pollGeneration

		let audio = DispatchWorkItem { [weak self] in
			while let self = self, self.pollGeneration == generation {
				if self.pollAudio() == PARSEC_NOT_RUNNING {
					usleep(50_000)
				}
			}
		}

		let event = DispatchWorkItem { [weak self] in
			var sawCursor = false
			while let self = self, self.pollGeneration == generation {
				if self.pollEvent(sawCursor: &sawCursor) {
					usleep(50_000)
				}
			}
		}

		DispatchQueue.global().async(execute: audio)
		DispatchQueue.global().async(execute: event)
	}

	func sendUserData(type: ParsecUserDataType, message: Data) {
        var nullTerminatedMessage = message
        nullTerminatedMessage.append(0)
		nullTerminatedMessage.withUnsafeBytes { ptr in
			let ptr2 = ptr.baseAddress?.assumingMemoryBound(to: CChar.self)
			ParsecClientSendUserData(_parsec, type.rawValue, ptr2)
		}
	}

	func updateHostVideoConfig() {
		var videoConfig = ParsecUserDataVideoConfig()
		let wantsAdaptive = displayMode == .adaptive &&
			!DataManager.model.adaptiveResolutionPaused &&
			SettingsHandler.resolution == .client &&
			DataManager.model.adaptiveRequestState.target != nil
		let requested = wantsAdaptive
			? (DataManager.model.requestedResolutionX, DataManager.model.requestedResolutionY)
			: (SettingsHandler.resolution == .client ? 0 : SettingsHandler.resolution.width,
			   SettingsHandler.resolution == .client ? 0 : SettingsHandler.resolution.height)
		videoConfig.video[0].resolutionX = requested.0
		videoConfig.video[0].resolutionY = requested.1
		videoConfig.video[0].encoderMaxBitrate = DataManager.model.bitrate
		videoConfig.video[0].fullFPS = DataManager.model.constantFps
		videoConfig.video[0].output = DataManager.model.output
		let encoder = JSONEncoder()
		let data = try! encoder.encode(videoConfig)
		CParsec.sendUserData(type: .setVideoConfig, message: data)
	}
}
