import SwiftUI
import ParsecSDK
import Foundation
import AVFoundation
import Combine

struct ParsecStatusBar: View {
	@Binding var showMenu: Bool
	@State var metricInfo: String = L("loading")
	@Binding var showDCAlert: Bool
	@Binding var DCAlertText: String
	@Binding var isReconnecting: Bool
	@Binding var connectionLost: Bool
	@Binding var waitingForNetwork: Bool
	@Binding var waitingForStream: Bool
	@State var networkFailureSince: Date?
	@State var frameHeld = false
	@State var parsecViewController: ParsecViewController?
	@State var wasDisconnected: Bool = true
	@State var liveSince: CFTimeInterval?
	@State var seenInterfaceChanges = NetworkWatcher.shared.interfaceChanges
	let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
	let onSilentDisconnect: () -> Void

	init(showMenu: Binding<Bool>, showDCAlert: Binding<Bool>, DCAlertText: Binding<String>, parsecViewController: ParsecViewController, isReconnecting: Binding<Bool>, connectionLost: Binding<Bool>, waitingForNetwork: Binding<Bool>, waitingForStream: Binding<Bool>, onSilentDisconnect: @escaping () -> Void) {
		_showMenu = showMenu
		_showDCAlert = showDCAlert
		_DCAlertText = DCAlertText
		_isReconnecting = isReconnecting
		_connectionLost = connectionLost
		_waitingForNetwork = waitingForNetwork
		_waitingForStream = waitingForStream
		self.parsecViewController = parsecViewController
		self.onSilentDisconnect = onSilentDisconnect
	}

	var body: some View {
		// Overlay elements
		if SettingsHandler.alwaysShowStatus {
			VStack {
				Text(metricInfo)
					.frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
					.multilineTextAlignment(.leading)
					.font(.system(size: 10))
					.lineSpacing(2)
					.fixedSize(horizontal: false, vertical: true)
					.padding(4)
			}
			.background(Rectangle().fill(Color("BackgroundPrompt").opacity(0.75)))
			.foregroundColor(Color("Foreground"))
			.frame(maxHeight: .infinity, alignment: .top)
			.zIndex(1)
			.edgesIgnoringSafeArea(.all)

		}
		EmptyView()
			.onReceive(timer) { _ in
				poll()
			}
	}

	func holdFrame(_ hold: Bool) {
		var pumping = false
		if #available(iOS 15.0, *) { pumping = PictureInPictureManager.shared.isPumping }
		if hold {
			frameHeld = true
			if !pumping { ParsecBackgroundManager.shared.glkViewController?.isPaused = true }
		} else if frameHeld {
			frameHeld = false
			if !pumping { ParsecBackgroundManager.shared.glkViewController?.isPaused = false }
		}
	}

	func pictureBack() {
		guard isReconnecting, liveSince != nil else { return }
		ParsecBackgroundManager.shared.onNextFrame = nil
		liveSince = nil
		withAnimation(.easeOut(duration: 0.3)) {
			isReconnecting = false
			waitingForStream = false
		}
		appNote("[reconnect] picture back")
	}

	func poll() {
		guard UIApplication.shared.applicationState != .inactive else { return }
		if showDCAlert || ParsecBackgroundManager.shared.isPaused || ParsecBackgroundManager.shared.endedByUser {
			return
		}

		var pcs = ParsecClientStatus()
		var status = CParsec.getStatusEx(&pcs)
		parsecViewController?.syncHostSizeIfNeeded()

		var pipActive = false
		if #available(iOS 15.0, *) {
			pipActive = PictureInPictureManager.shared.isPiPActive
		}
		let offline = NetworkWatcher.shared.noNetwork

		if waitingForNetwork {
			if offline {
				holdFrame(true)
				return
			}
			waitingForNetwork = false
			ParsecBackgroundManager.shared.resumedAt = Date()
			if let peerId = ParsecBackgroundManager.shared.lastPeerId {
				let mgr = ParsecBackgroundManager.shared
				mgr.reconnectAttempts = 1
				appNote("[reconnect] network back, reconnecting")
				isReconnecting = true
				parsecViewController?.resetKeyState()
				CParsec.reconnect(peerId)
				mgr.reconnectStartTime = Date()
				return
			}
		}

		if status == PARSEC_OK && !isReconnecting && !pipActive {
			if offline {
				appNote("[stream] no network, not waiting on sdk")
				status = NETWORK_ERR_INTERRUPTED
			} else if SettingsHandler.autoReconnect && NetworkWatcher.shared.interfaceChanges != seenInterfaceChanges {
				appNote("[stream] network interface changed, reconnecting")
				status = NETWORK_ERR_INTERRUPTED
			}
		}
		seenInterfaceChanges = NetworkWatcher.shared.interfaceChanges

		if status == PARSEC_OK && pcs.networkFailure && !isReconnecting && !pipActive {
			if networkFailureSince == nil { networkFailureSince = Date() }
			let lost = Date().timeIntervalSince(networkFailureSince!)
			let justResumed = Date().timeIntervalSince(ParsecBackgroundManager.shared.resumedAt ?? .distantPast) < 10
			connectionLost = true
			if lost >= 3 || justResumed {
				networkFailureSince = nil
				connectionLost = false
				ParsecBackgroundManager.shared.resumedAt = nil
				status = NETWORK_ERR_INTERRUPTED
				appNote("[stream] network failure held, treating it as a lost connection")
			}
		} else {
			networkFailureSince = nil
			connectionLost = false
		}

		if status != PARSEC_OK {
			liveSince = nil
			waitingForStream = false
			ParsecBackgroundManager.shared.onNextFrame = nil
			holdFrame(true)
			if ParsecBackgroundManager.shared.isMarkedForReconnect {
				return
			}

			if offline && !pipActive {
				isReconnecting = false
				connectionLost = false
				if SettingsHandler.autoReconnect && ParsecBackgroundManager.shared.lastPeerId != nil {
					ParsecBackgroundManager.shared.reconnectAttempts = 0
					waitingForNetwork = true
					appNote("[stream] no network, waiting")
					return
				}
				appNote("[stream] ended, no network, alert")
				DCAlertText = L("no_network")
				showDCAlert = true
				return
			}

			let setupFailure = isReconnecting ? CParsec.setupError.flatMap { $0.at > ParsecBackgroundManager.shared.reconnectStartTime ? $0.line : nil } : nil

			if status == PARSEC_CONNECTING && isReconnecting && setupFailure == nil {
				if Date().timeIntervalSince(ParsecBackgroundManager.shared.reconnectStartTime) < 15 {
					return
				}
			}

			if status == CONNECT_WRN_APPROVAL && isReconnecting && setupFailure == nil {
				if Date().timeIntervalSince(ParsecBackgroundManager.shared.reconnectStartTime) < 60 {
					return
				}
			}

			// PiP: connection died (screen lock killed GPU). Kill connection+audio once,
			// subsequent polls exit via isMarkedForReconnect above.
			if pipActive {
				appNote("[stream] lost during picture in picture, status \(status.rawValue), reconnect owed")
				CParsec.disconnect()
				try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
				ParsecBackgroundManager.shared.connectionDidEnd()
				ParsecBackgroundManager.shared.markForReconnect()
				wasDisconnected = true
				return
			}

			if SettingsHandler.autoReconnect, !status.isPermanentFailure || (status == CONNECT_WRN_APPROVAL && setupFailure != nil), let peerId = ParsecBackgroundManager.shared.lastPeerId {
				let mgr = ParsecBackgroundManager.shared
				if mgr.reconnectAttempts < 3 {
					let gap: TimeInterval = mgr.reconnectAttempts == 0 ? 0 : mgr.reconnectAttempts == 1 ? 2 : 5
					if Date().timeIntervalSince(mgr.reconnectStartTime) < gap {
						return
					}
					mgr.reconnectAttempts += 1
					appNote("[reconnect] attempt \(mgr.reconnectAttempts) after status \(status.rawValue)\(setupFailure.map { ", sdk setup failed: \($0)" } ?? "")")
					isReconnecting = true
					parsecViewController?.resetKeyState()
					CParsec.reconnect(peerId)
					mgr.reconnectStartTime = Date()
					return
				}
				mgr.reconnectAttempts = 0
			}

			isReconnecting = false
			wasDisconnected = true
			let silent = SettingsHandler.autoReconnect && !SettingsHandler.errorPrompts && !status.isPermanentFailure
			appNote("[stream] ended, status \(status.rawValue), \(silent ? "silent" : "alert")")
			if silent {
				// silent: auto-reconnect spent its retries, dont nag with an alert
				onSilentDisconnect()
			} else {
				DCAlertText = status.connectionMessage()
				showDCAlert = true
			}
			return
		}

		holdFrame(connectionLost)

		if isReconnecting {
			if liveSince == nil {
				liveSince = CACurrentMediaTime()
				withAnimation(.easeInOut(duration: 0.2)) { waitingForStream = true }
				ParsecBackgroundManager.shared.onNextFrame = { pictureBack() }
				ParsecBackgroundManager.shared.reconnectAttempts = 0
				appNote("[reconnect] live again")
				ParsecView.getHostUserData()
				// SDK forgets stream dims on reconnect, re-send them so the frame fills not corners
				if let vc = parsecViewController {
					vc.applyDisplayMode()
				}
			}
			if CParsec.runningRenderer != .metal || CACurrentMediaTime() - liveSince! > 6 {
				pictureBack()
			}
		}

		if SettingsHandler.alwaysShowStatus {
			let str = String.fromBuffer(&pcs.decoder.0.name.0, length: 16)
			let model = DataManager.model
			let adaptive = (CParsec.parsecImpl as? ParsecSDKBridge)?.adaptiveDiagnostic ?? "自适应：关闭"
			let requested = model.requestedResolutionX > 0
				? "\(model.requestedResolutionX)x\(model.requestedResolutionY)"
				: "-"
			let actual = model.actualFrameWidth > 0
				? "\(model.actualFrameWidth)x\(model.actualFrameHeight)"
				: "等待帧"
			let picture = model.pictureWidth > 0
				? "\(model.pictureX),\(model.pictureY) \(model.pictureWidth)x\(model.pictureHeight)"
				: "-"
			let decoder = model.decoderWidth > 0
				? "\(model.decoderWidth)x\(model.decoderHeight)"
				: "\(pcs.decoder.0.width)x\(pcs.decoder.0.height)"
			metricInfo = "画面：解码 \(decoder)  帧 \(actual)  请求 \(requested)  视口 \(model.viewportWidth)x\(model.viewportHeight)  画面矩形 \(picture)  \(adaptive)\n解码 \(String(format: "%.2f", pcs.`self`.metrics.0.decodeLatency))ms  编码 \(String(format: "%.2f", pcs.`self`.metrics.0.encodeLatency))ms  网络 \(String(format: "%.2f", pcs.`self`.metrics.0.networkLatency))ms  码率 \(String(format: "%.2f", pcs.`self`.metrics.0.bitrate))Mbps  重传 \(pcs.`self`.metrics.0.fastRTs + pcs.`self`.metrics.0.slowRTs)  队列 \(pcs.`self`.metrics.0.queuedFrames)  绘制 \(String(format: "%.0f", CParsec.drawRate))fps \(CParsec.rendererName)  \(pcs.decoder.0.h265 ? "H265" : "H264") \(pcs.decoder.0.color444 ? "4:4:4" : "4:2:0") \(str)"
		}
	}


}

// CRITICAL: This class exists to PERSIST the ParsecViewController instance across SwiftUI view updates.
// Do not remove or change to a struct. If ParsecViewController is recreated, the keyboard responder chain breaks.
class ParsecSession: ObservableObject {
    let controller: ParsecViewController

    init() {
        self.controller = ParsecViewController()
    }
}

enum StreamAlert: Identifiable {
	case disconnect(String)
	case exit

	var id: String {
		switch self {
		case .disconnect(let message): return "disconnect-\(message)"
		case .exit: return "exit"
		}
	}
}

struct ParsecView: View {
	var controller: ContentView?

	@State var showDCAlert: Bool = false
	@State var DCAlertText: String = L("status_disconnected")
	@State var metricInfo: String = L("loading")

	@State var hideOverlay: Bool = false
	@State var hideKeyboardButton: Bool = false
	@AppStorage("keyboardHintShown") var keyboardHintShown: Bool = false
	@AppStorage("keyboardPanHintShown") var keyboardPanHintShown: Bool = false
	@AppStorage("mobileGestureHintShown") var mobileGestureHintShown: Bool = false
	@State var hint: String?
	@State var showMenu: Bool = false
	@AppStorage("menuSwipeHintShown") var menuSwipeHintShown: Bool = false

	@State var showKeyboard: Bool = false
	@State var zoomEnabled: Bool = false
	@State var viewOnly: Bool = false
	@State var showFullDiagnostics: Bool = false
	@State var activeAlert: StreamAlert?

	@State var muted: Bool = false
	@State var preferH265: Bool = true
	@State var isReconnecting: Bool = false
	@State var connectionLost: Bool = false
	@State var showSettings: Bool = false
	@State var decoderAtOpen: DecoderPref = .h264
	@State var fpsAtOpen: Int = 0
	@State var pipAtOpen: Bool = false
	@State var resolutionAtOpen: ParsecResolution = .client
	@State var bitrateAtOpen: Int = 0
	@State var waitingForNetwork: Bool = false
	@State var waitingForStream: Bool = false

	@State var resolutions: [ParsecResolution]
	@State var bitrates: [Int]

    // Persist the VC across view updates using StateObject.
    // CRITICAL: Changing this to @State or a simple var will break the keyboard after menu interactions.
	@StateObject var session = ParsecSession()

    // Observer shared state for updates
    @ObservedObject var dataModel = DataManager.model
	@ObservedObject var settingsStore = SettingsStore.shared

    // Computed property for convenience refactoring
    var parsecViewController: ParsecViewController {
        return session.controller
    }

	// @State var showDisplays: Bool = false

	init(_ controller: ContentView?) {
		self.controller = controller

		_muted = State(initialValue: SettingsHandler.startMuted)
		_zoomEnabled = State(initialValue: SettingsHandler.zoomEnabled)
		_resolutions = State(initialValue: ParsecResolution.resolutions)
		_bitrates = State(initialValue: ParsecResolution.bitrates)

    }

    // We need to set up the callback somewhere safer than init.
    // 'onAppear' is a good place, or inside the init of ParsecSession if possible (but it doesn't have access to binding).
    // Let's use onAppear/post.

	var body: some View {
		ZStack {

			UIViewControllerWrapper(self.parsecViewController)
				.zIndex(1)
				.prefersPersistentSystemOverlaysHidden()

			ParsecStatusBar(showMenu: $showMenu, showDCAlert: $showDCAlert, DCAlertText: $DCAlertText, parsecViewController: parsecViewController, isReconnecting: $isReconnecting, connectionLost: $connectionLost, waitingForNetwork: $waitingForNetwork, waitingForStream: $waitingForStream, onSilentDisconnect: { disconnect() })

			if isReconnecting || connectionLost || waitingForNetwork {
				VStack(spacing: 12) {
					if waitingForNetwork {
						Image(systemName: "wifi.slash")
							.font(.system(size: 34, weight: .medium))
							.foregroundColor(.white)
					} else {
						ActivityIndicator(isAnimating: .constant(true), style: .large, tint: .white)
					}
					Text(overlayTitle)
						.font(.system(size: 16, weight: .medium))
						.foregroundColor(.white)
						.id(waitingForStream)
						.transition(.opacity)
					if waitingForNetwork {
						Text(L("will_reconnect_online"))
							.font(.system(size: 13))
							.foregroundColor(.white)
							.opacity(0.7)
					}
					Button(action: { disconnect() }) {
						Text(L("close"))
							.font(.system(size: 15, weight: .semibold))
							.foregroundColor(.white)
							.padding(.horizontal, 20)
							.frame(minHeight: 44)
							.background(Color.white.opacity(0.2))
							.cornerRadius(8)
					}
					.padding(.top, 4)
					if settingsStore.showConnectionLog {
						ConnectionLogPanel()
					}
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.background(Color.black.opacity(0.6))
				.transition(.asymmetric(insertion: .identity, removal: .opacity))
				.zIndex(10)
			}

			if dataModel.isBlocked {
				Text(L("host_using_machine"))
					.foregroundColor(.white)
					.padding(.horizontal, 16)
					.padding(.vertical, 10)
					.background(Color("BackgroundPrompt").opacity(0.85))
					.cornerRadius(8)
					.zIndex(3)
			}

			if let hint = hint {
				Text(hint)
					.multilineTextAlignment(.center)
					.foregroundColor(.white)
					.padding(.horizontal, 16)
					.padding(.vertical, 10)
					.background(Color("BackgroundPrompt").opacity(0.85))
					.cornerRadius(8)
					.padding(.top, showKeyboard ? 100 : 0)
					.frame(maxHeight: .infinity, alignment: showKeyboard ? .top : .center)
					.allowsHitTesting(false)
					.zIndex(3)
			}

			if !hideOverlay || showMenu {
				streamControlPanel
					.zIndex(2)
			}
		}
		.statusBarHidden(SettingsHandler.hideStatusBar)
		.alert(item: $activeAlert) { alert in
			switch alert {
			case .disconnect(let message):
				return Alert(
					title: Text(message),
					primaryButton: .default(Text(L("reconnect")), action: {
						guard let peerId = ParsecBackgroundManager.shared.lastPeerId else {
							disconnect()
							return
						}
						if NetworkWatcher.shared.noNetwork {
							DCAlertText = L("no_network")
							activeAlert = .disconnect(L("no_network"))
							return
						}
						activeAlert = nil
						reconnectTo(peerId)
					}),
					secondaryButton: .cancel(Text(L("close")), action: { disconnect() })
				)
			case .exit:
				return Alert(
					title: Text(L("stream_exit_confirm_title")),
					message: Text(L("stream_exit_confirm_message")),
					primaryButton: .destructive(Text(L("stream_exit"))) { disconnect() },
					secondaryButton: .cancel(Text(L("cancel")))
				)
			}
		}
		.onChange(of: showDCAlert) { shown in
			guard shown else { return }
			showDCAlert = false
			activeAlert = .disconnect(DCAlertText)
		}
		.onChange(of: showSettings) { open in
			if !open { applyStreamSettings() }
		}
		.onChange(of: isReconnecting) { reconnecting in
			if !reconnecting {
				CParsec.setMuted(muted)
				if muted { CParsec.pause(video: false, audio: true) }
			}
		}
		.onAppear(perform: post)
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("RemoteTextInputFailure"))) { notification in
			let message = (notification.userInfo?["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
			guard let message = message, !message.isEmpty else { return }
			withAnimation { hint = message }
			DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
				if hint == message {
					withAnimation { hint = nil }
				}
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
			DispatchQueue.main.async {
				guard SettingsHandler.streamDisplayMode == .adaptive else { return }
				parsecViewController.requestAdaptiveResolutionIfNeeded()
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ParsecBackgroundDisconnect"))) { _ in
			if #available(iOS 15.0, *) {
				if PictureInPictureManager.shared.isPiPActive {
					return
				}
			}
			disconnect(isBackgroundDisconnect: true)
		}
		.edgesIgnoringSafeArea(.all)
		.overlay(SettingsView(visible: $showSettings))

	}

	var streamControlPanel: some View {
		StreamControlPanel(
			cursorMode: Binding(
				get: { settingsStore.cursorMode },
				set: { setCursorMode($0) }
			),
			virtualMouseEnabled: Binding(
				get: { settingsStore.virtualMouseEnabled },
				set: { setVirtualMouseEnabled($0) }
			),
			virtualMouseScale: Binding(
				get: { settingsStore.virtualMouseScale },
				set: { setVirtualMouseScale($0) }
			),
			resolution: Binding(
				get: { settingsStore.resolution },
				set: { changeResolution(res: $0) }
			),
			bitrate: Binding(
				get: { settingsStore.bitrate },
				set: { changeBitRate(bitrate: $0) }
			),
			showFullDiagnostics: $showFullDiagnostics,
			resolutions: resolutions,
			bitrates: bitrates,
			state: StreamControlState(
				isOpen: showMenu,
				isViewOnly: viewOnly,
				isMuted: muted,
				keyboardVisible: showKeyboard,
				isAdaptiveDisplay: settingsStore.streamDisplayMode == .adaptive,
				isPinchZoomEnabled: zoomEnabled,
				isConstantFps: dataModel.constantFps,
				isKeyboardButtonVisible: !settingsStore.noOverlay && settingsStore.showKeyboardButton,
				textInputMode: settingsStore.textInputMode,
				displays: dataModel.displayConfigs,
				selectedDisplay: dataModel.output,
				adaptiveStatus: settingsStore.streamDisplayMode == .adaptive ? adaptiveStatusText : nil,
				diagnosticsSummary: diagnosticsSummary,
				fullDiagnostics: diagnosticsFull
			),
			actions: StreamControlActions(
				setOpen: { open in setPanelOpen(open) },
				setCursorMode: { mode in setCursorMode(mode) },
				toggleVirtualMouse: { setVirtualMouseEnabled(!settingsStore.virtualMouseEnabled) },
				setVirtualMouseScale: { scale in setVirtualMouseScale(scale) },
				resetVirtualMousePosition: { resetVirtualMousePosition() },
				setResolution: { resolution in changeResolution(res: resolution) },
				setBitrate: { bitrate in changeBitRate(bitrate: bitrate) },
				setDisplay: { id in changeDisplay(displayId: id) },
				toggleMute: { toggleMute() },
				toggleViewOnly: { toggleViewOnly() },
				resetView: { resetViewport() },
				openSettings: { openSettings() },
				toggleDisplayMode: { toggleDisplayMode() },
				toggleZoom: { toggleZoom() },
				toggleConstantFps: { toggleConstantFps() },
				setTextInputMode: { mode in setTextInputMode(mode) },
				rightClick: { rightClick() },
				hideButtons: { disableOverlay() },
				toggleKeyboard: { toggleKeyboard() },
				showDesktop: { sendSystemShortcut(.showDesktop) },
				switchWindow: { sendSystemShortcut(.switchWindow) },
				exit: { activeAlert = .exit }
			)
		)
		.allowsHitTesting(!hideOverlay || showMenu)
	}

	var overlayTitle: String {
		if waitingForNetwork {
			return L("no_network")
		}
		if !isReconnecting {
			return L("connection_lost")
		}
		if waitingForStream {
			return L("reconnected_waiting")
		}
		return ParsecBackgroundManager.shared.lastHostname.map { String(format: L("reconnecting_to"), $0) } ?? L("reconnecting")
	}

	var adaptiveStatusText: String {
		switch dataModel.adaptiveRequestState {
		case .inactive:
			return L("stream_adaptive_off")
		case .waiting(let target, _):
			return String(format: L("stream_adaptive_waiting"), "\(target.width)×\(target.height)")
		case .matched(let target):
			return String(format: L("stream_adaptive_matched"), "\(target.width)×\(target.height)")
		case .unmatched(let target):
			return String(format: L("stream_adaptive_unmatched"), "\(target.width)×\(target.height)")
		}
	}

	var diagnosticsSummary: String? {
		guard settingsStore.streamDisplayMode == .adaptive else { return nil }
		let frame = dataModel.actualFrameWidth > 0
			? "\(dataModel.actualFrameWidth)×\(dataModel.actualFrameHeight)"
			: "-"
		let decoder = dataModel.decoderWidth > 0
			? "\(dataModel.decoderWidth)×\(dataModel.decoderHeight)"
			: "-"
		return String(format: L("stream_diagnostics_summary"), frame, decoder, CParsec.drawRate)
	}

	var diagnosticsFull: String? {
		guard settingsStore.streamDisplayMode == .adaptive else { return nil }
		let requested = dataModel.requestedResolutionX > 0
			? "\(dataModel.requestedResolutionX)×\(dataModel.requestedResolutionY)"
			: "-"
		let picture = dataModel.pictureWidth > 0
			? "\(dataModel.pictureX),\(dataModel.pictureY) \(dataModel.pictureWidth)×\(dataModel.pictureHeight)"
			: "-"
		return "请求 \(requested)\n视口 \(dataModel.viewportWidth)×\(dataModel.viewportHeight)\n画面矩形 \(picture)"
	}

	func post() {
		ParsecBackgroundManager.shared.onShouldDisconnect = {
			NotificationCenter.default.post(name: NSNotification.Name("ParsecBackgroundDisconnect"), object: nil)
		}
		ParsecBackgroundManager.shared.onEndedInBackground = { [self] in
			ParsecBackgroundManager.shared.onNextFrame = nil
			waitingForStream = false
			if showDCAlert || waitingForNetwork { return }
			isReconnecting = true
		}
		ParsecBackgroundManager.shared.onResumeEndedSession = { [self] in
			if showDCAlert || waitingForNetwork { return }
			guard let peerId = ParsecBackgroundManager.shared.lastPeerId else { return }
			appNote("[reconnect] back from the background, reconnecting")
			reconnectTo(peerId)
			ParsecBackgroundManager.shared.reconnectAttempts = 1
		}
		if #available(iOS 15.0, *) {
			PictureInPictureManager.shared.onPiPStopped = { [self] in
				if UIApplication.shared.applicationState != .active {
					ParsecBackgroundManager.shared.glkViewController?.isPaused = true
					CParsec.sendReleaseMessage()
					CParsec.pause()
					ParsecBackgroundManager.shared.isPaused = true
					if UIApplication.shared.applicationState == .background {
						ParsecBackgroundManager.shared.holdSessionInBackground()
					}
				} else {
					if ParsecBackgroundManager.shared.isReconnecting {
						return
					}
					// Check actual Parsec status — timers don't reliably fire in background
					var pcs = ParsecClientStatus()
					let currentStatus = CParsec.getStatusEx(&pcs)
					if currentStatus != PARSEC_OK || ParsecBackgroundManager.shared.isMarkedForReconnect {
						CParsec.disconnect()
						try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
						ParsecBackgroundManager.shared.markForReconnect()
						DispatchQueue.main.async {
							self.disconnect(isBackgroundDisconnect: true)
						}
					}
				}
			}
			PictureInPictureManager.shared.onPiPStartFailed = {
				if UIApplication.shared.applicationState != .active {
					ParsecBackgroundManager.shared.glkViewController?.isPaused = true
					CParsec.sendReleaseMessage()
					CParsec.pause()
					ParsecBackgroundManager.shared.isPaused = true
					if UIApplication.shared.applicationState == .background {
						ParsecBackgroundManager.shared.holdSessionInBackground()
					}
				}
			}
		}

		CParsec.applyConfig()
		CParsec.setMuted(muted)
		if muted { CParsec.pause(video: false, audio: true) }
		parsecViewController.setZoomEnabled(zoomEnabled)

		DataManager.model.constantFps = SettingsHandler.constantFps
		let screenSize: CGSize = self.parsecViewController.view.frame.size
		let scaleFactor = UIScreen.main.nativeScale
		ParsecResolution.updateClientResolution(width: Int(screenSize.width * scaleFactor), height: Int(screenSize.height * scaleFactor))
		parsecViewController.requestAdaptiveResolutionIfNeeded()

		ParsecView.getHostUserData()

		hideOverlay = SettingsHandler.noOverlay
		hideKeyboardButton = !SettingsHandler.showKeyboardButton
		parsecViewController.updateMenuEdgeSwipe(menuHidden: hideOverlay)
		parsecViewController.applyVirtualMouseSettings()
		parsecViewController.setInteractionEnabled(!viewOnly)
		parsecViewController.setVirtualMouseSuspended(!SettingsHandler.virtualMouseEnabled || viewOnly || hideOverlay)
		offerHint()

		let overlayHidden = $hideOverlay
		let keyboardButtonHidden = $hideKeyboardButton
		let menuShown = $showMenu
		parsecViewController.onMenuEdgeSwipe = {
			overlayHidden.wrappedValue = false
			keyboardButtonHidden.wrappedValue = !SettingsHandler.showKeyboardButton
			menuShown.wrappedValue = true
			parsecViewController.releaseMobileInteractions()
			parsecViewController.setVirtualMouseSuspended(true)
			ParsecView.getHostUserData()
		}

        let keyboardShown = $showKeyboard
        parsecViewController.onKeyboardVisibilityChanged = { visible in
            keyboardShown.wrappedValue = visible
        }
		let hint = $hint
		let panHintShown = $keyboardPanHintShown
		parsecViewController.onKeyboardCoversPicture = {
			guard !panHintShown.wrappedValue else { return }
			panHintShown.wrappedValue = true
			withAnimation { hint.wrappedValue = L("keyboard_cover_hint") }
			DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
				withAnimation { hint.wrappedValue = nil }
			}
		}

		parsecViewController.setKeyboardVisible(showKeyboard)
		showMobileGestureHintIfNeeded()
	}

	func openSettings() {
		decoderAtOpen = SettingsHandler.decoder
		fpsAtOpen = SettingsHandler.preferredFramesPerSecond
		pipAtOpen = SettingsHandler.enablePiP
		resolutionAtOpen = SettingsHandler.resolution
		bitrateAtOpen = SettingsHandler.bitrate
		setPanelOpen(false)
		parsecViewController.setVirtualMouseSuspended(true)
		if showKeyboard { toggleKeyboard() }
		withAnimation(.easeInOut(duration: 0.24)) { showSettings = true }
	}

	func applyStreamSettings() {
		let displayModeBeforeSettings = parsecViewController.displayMode
		let modeChanged = displayModeBeforeSettings != SettingsHandler.streamDisplayMode
		if modeChanged && SettingsHandler.streamDisplayMode == .adaptive {
			SettingsHandler.resolution = .client
		}
		DataManager.model.adaptiveResolutionPaused = SettingsHandler.resolution != .client
		if modeChanged || SettingsHandler.resolution != resolutionAtOpen {
			parsecViewController.resetAdaptiveResolutionRequest()
		}
		zoomEnabled = SettingsHandler.zoomEnabled
		parsecViewController.setZoomEnabled(zoomEnabled)
		parsecViewController.displayMode = SettingsHandler.streamDisplayMode
		parsecViewController.applyDisplayMode()
		parsecViewController.requestAdaptiveResolutionIfNeeded()
		parsecViewController.updatePanHandle()
		parsecViewController.positionCursorOverlay()
		parsecViewController.applyVirtualMouseSettings()
		parsecViewController.setVirtualMouseSuspended(viewOnly
			|| !SettingsHandler.virtualMouseEnabled
			|| hideOverlay)
		hideOverlay = SettingsHandler.noOverlay
		hideKeyboardButton = !SettingsHandler.showKeyboardButton
		parsecViewController.updateMenuEdgeSwipe(menuHidden: hideOverlay)
		parsecViewController.setInteractionEnabled(!viewOnly)
		offerHint()
		if SettingsHandler.clipboardSync { ClipboardSync.shared.start() } else { ClipboardSync.shared.stop() }

		var hostConfigChanged = false
		if SettingsHandler.resolution != resolutionAtOpen {
			if SettingsHandler.resolution != .client {
				DataManager.model.requestedResolutionX = SettingsHandler.resolution.width
				DataManager.model.requestedResolutionY = SettingsHandler.resolution.height
			}
			hostConfigChanged = true
		}
		if SettingsHandler.constantFps != DataManager.model.constantFps {
			DataManager.model.constantFps = SettingsHandler.constantFps
			hostConfigChanged = true
		}
		if hostConfigChanged { CParsec.updateHostVideoConfig() }
		if SettingsHandler.bitrate != bitrateAtOpen { applyBitrate() }
		if SettingsHandler.preferredFramesPerSecond != fpsAtOpen { parsecViewController.applyFrameRate() }
		if SettingsHandler.enablePiP != pipAtOpen {
			ParsecBackgroundManager.shared.reconnectPending = true
			disconnect()
		} else if SettingsHandler.decoder != decoderAtOpen {
			reconnectToApply()
		}
	}

	func reconnectToApply() {
		guard let peerId = ParsecBackgroundManager.shared.lastPeerId else { return }
		appNote("[reconnect] to apply settings")
		reconnectTo(peerId)
	}

	func reconnectTo(_ peerId: String) {
		isReconnecting = true
		ParsecBackgroundManager.shared.reconnectAttempts = 0
		parsecViewController.resetKeyState()
		CParsec.reconnect(peerId)
		ParsecBackgroundManager.shared.reconnectStartTime = Date()
	}

	func disableOverlay() {
		hideOverlay = true
		hideKeyboardButton = true
		parsecViewController.setVirtualMouseSuspended(true)
		setPanelOpen(false)
		parsecViewController.updateMenuEdgeSwipe(menuHidden: true)
		offerHint(always: true)
	}

	func restoreOverlay() {
		hideOverlay = false
		hideKeyboardButton = !SettingsHandler.showKeyboardButton
		parsecViewController.setVirtualMouseSuspended(!SettingsHandler.virtualMouseEnabled || viewOnly)
		parsecViewController.updateMenuEdgeSwipe(menuHidden: false)
	}

	func setPanelOpen(_ open: Bool) {
		parsecViewController.releaseMobileInteractions()
		if open && showKeyboard {
			showKeyboard = false
			parsecViewController.setKeyboardVisible(false)
		}
		showMenu = open
		parsecViewController.setVirtualMouseSuspended(open || viewOnly
			|| !SettingsHandler.virtualMouseEnabled || hideOverlay)
		if open {
			showFullDiagnostics = false
			ParsecView.getHostUserData()
		}
	}

	func offerHint(always: Bool = false) {
		let menu = hideOverlay && (always || !menuSwipeHintShown)
		let keyboard = hideKeyboardButton && (always || !keyboardHintShown)
		guard menu || keyboard else { return }
		if menu { menuSwipeHintShown = true }
		if keyboard { keyboardHintShown = true }
		let text = [menu ? L("menu_swipe_hint") : nil, keyboard ? L("keyboard_hint") : nil].compactMap { $0 }.joined(separator: "\n")
		withAnimation { hint = text }
		DispatchQueue.main.asyncAfter(deadline: .now() + (menu && keyboard ? 6 : 4)) {
				if hint == text {
					withAnimation { hint = nil }
				}
		}
	}

	func showMobileGestureHintIfNeeded() {
		guard !mobileGestureHintShown else { return }
		mobileGestureHintShown = true
		withAnimation { hint = L("gesture_tips") }
		DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
			if hint == L("gesture_tips") {
				withAnimation { hint = nil }
			}
		}
	}

	func toggleMute() {
		muted.toggle()
		CParsec.setMuted(muted)
		if muted {
			CParsec.pause(video: false, audio: true)
		} else {
			CParsec.resume()
		}
	}

		/*func genDisplaySheet() -> ActionSheet
	{
		let len:Int = 16
		var outputs = [ParsecOutput?](repeating:nil, count:len)
		ParsecGetOutputs(&outputs, UInt32(len))
		print("Listing \(outputs.count) displays")

		func getDeviceName(_ output:ParsecOutput) -> String
		{
			return withUnsafePointer(to:output.device)
			{
				$0.withMemoryRebound(to: UInt8.self, capacity:MemoryLayout.size(ofValue:$0))
				{
					String(cString:$0)
				}
			}
		}

		let buttons = outputs.enumerated().map
		{ i, output in
			Alert.Button.default(Text("\(i) - \(getDeviceName(output))"), action:{print("Selected device \(i)")})
		}
		return ActionSheet(title: Text(L("select_display")), buttons:buttons + [Alert.Button.cancel()])
	}*/

	func disconnect(isBackgroundDisconnect: Bool = false) {
		parsecViewController.releaseMobileInteractions()
		parsecViewController.setVirtualMouseSuspended(true)
		appNote("[stream] disconnect\(isBackgroundDisconnect ? " in the background" : "")")
		if !isBackgroundDisconnect {
			ParsecBackgroundManager.shared.endSession()
		}
		ParsecBackgroundManager.shared.onResumeEndedSession = nil
		ParsecBackgroundManager.shared.onEndedInBackground = nil
		ParsecBackgroundManager.shared.onNextFrame = nil

		if #available(iOS 15.0, *) {
			PictureInPictureManager.shared.teardown()
		}

		CParsec.sendReleaseMessage()
		CParsec.disconnect()
		DataManager.model.output = "none"
		CParsec.drawRate = 0
		self.parsecViewController.glkView.cleanUp()

		parsecViewController.scrollView.zoomScale = 1.0
		parsecViewController.scrollView.contentOffset = .zero
		parsecViewController.resetAdaptiveResolutionRequest()

		if let c = controller {
			c.setView(.main)
		}
	}

	func changeResolution(res: ParsecResolution) {
        SettingsHandler.resolution = res
		DispatchQueue.main.async {
			parsecViewController.resetAdaptiveResolutionRequest()
			if res == .client {
				DataManager.model.adaptiveResolutionPaused = false
				parsecViewController.requestAdaptiveResolutionIfNeeded()
			} else {
				if SettingsHandler.streamDisplayMode == .adaptive {
					DataManager.model.adaptiveResolutionPaused = true
				}
				DataManager.model.requestedResolutionX = res.width
				DataManager.model.requestedResolutionY = res.height
				DataManager.model.adaptiveRequestState = .inactive
				CParsec.updateHostVideoConfig()
			}
		}
	}

	func changeBitRate(bitrate: Int) {
		SettingsHandler.bitrate = bitrate
		applyBitrate()
	}

	func applyBitrate() {
		let target = SettingsHandler.bitrate > 0 ? SettingsHandler.bitrate : DataManager.model.hostDefaultBitrate
		guard target > 0, target != DataManager.model.bitrate else { return }
		DataManager.model.bitrate = target
		CParsec.updateHostVideoConfig()
	}

	func toggleConstantFps() {
		DispatchQueue.main.async {
			DataManager.model.constantFps.toggle()
			CParsec.updateHostVideoConfig()
			SettingsHandler.constantFps = DataManager.model.constantFps
		}
	}

	func toggleKeyboard() {
		DispatchQueue.main.async {
			guard !viewOnly else { return }
			if !showKeyboard { setPanelOpen(false) }
			showKeyboard.toggle()
			parsecViewController.setKeyboardVisible(showKeyboard)
		}
	}

	func toggleZoom() {
		DispatchQueue.main.async {
			zoomEnabled.toggle()
			parsecViewController.setZoomEnabled(zoomEnabled)
			SettingsHandler.zoomEnabled = zoomEnabled
		}
	}

	func toggleTouchMode() {
		DispatchQueue.main.async {
			SettingsHandler.cursorMode = SettingsHandler.cursorMode == .direct ? .touchpad : .direct
			parsecViewController.updatePanHandle()
		}
	}

	func setCursorMode(_ mode: CursorMode) {
		guard mode != SettingsHandler.cursorMode else { return }
		parsecViewController.releaseMobileInteractions()
		SettingsHandler.cursorMode = mode
		parsecViewController.updatePanHandle()
	}

	func setVirtualMouseEnabled(_ enabled: Bool) {
		SettingsHandler.virtualMouseEnabled = enabled
		parsecViewController.applyVirtualMouseSettings()
		parsecViewController.setVirtualMouseSuspended(showMenu || !enabled || viewOnly || hideOverlay)
	}

	func setVirtualMouseScale(_ scale: Double) {
		SettingsHandler.virtualMouseScale = scale
		parsecViewController.applyVirtualMouseSettings()
	}

	func resetVirtualMousePosition() {
		SettingsHandler.virtualMousePositionX = 0.8
		SettingsHandler.virtualMousePositionY = 0.65
		parsecViewController.applyVirtualMouseSettings()
	}

	func toggleViewOnly() {
		viewOnly.toggle()
		parsecViewController.setVirtualMouseSuspended(showMenu || viewOnly || !SettingsHandler.virtualMouseEnabled || hideOverlay)
		parsecViewController.setInteractionEnabled(!viewOnly)
		if !viewOnly {
			parsecViewController.setVirtualMouseSuspended(showMenu || !SettingsHandler.virtualMouseEnabled || hideOverlay)
		}
		let message = L(viewOnly ? "stream_view_only_hint" : "stream_view_only_restored")
		withAnimation { hint = message }
		DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
			if hint == message {
				withAnimation { hint = nil }
			}
		}
	}

	func setTextInputMode(_ mode: TextInputMode) {
		guard mode != settingsStore.textInputMode else { return }
		toggleTextInputMode()
	}

	func sendSystemShortcut(_ shortcut: RemoteSystemShortcut) {
		guard !viewOnly, UIApplication.shared.applicationState == .active,
			  ParsecBackgroundManager.shared.hasActiveConnection else { return }
		CParsec.sendSystemShortcut(shortcut)
	}

	func toggleTextInputMode() {
		DispatchQueue.main.async {
			CParsec.cancelPendingTextInput()
			settingsStore.textInputMode = settingsStore.textInputMode == .text ? .keys : .text
			parsecViewController.setKeyboardVisible(showKeyboard)
		}
	}

	func resetViewport() {
		parsecViewController.resetViewport()
	}

	func rightClick() {
		setPanelOpen(false)
		DispatchQueue.main.async {
			guard UIApplication.shared.applicationState == .active,
				  ParsecBackgroundManager.shared.hasActiveConnection else { return }
			CParsec.sendMouseClickMessage(MOUSE_R, true)
			CParsec.sendMouseClickMessage(MOUSE_R, false)
		}
	}

	func toggleDisplayMode() {
		DispatchQueue.main.async {
			settingsStore.streamDisplayMode = settingsStore.streamDisplayMode == .adaptive ? .original : .adaptive
			parsecViewController.displayMode = settingsStore.streamDisplayMode
			parsecViewController.resetAdaptiveResolutionRequest()
			if settingsStore.streamDisplayMode == .adaptive {
				SettingsHandler.resolution = .client
				DataManager.model.adaptiveResolutionPaused = false
			} else {
				DataManager.model.adaptiveRequestState = .inactive
				DataManager.model.requestedResolutionX = 0
				DataManager.model.requestedResolutionY = 0
			}
			parsecViewController.applyDisplayMode()
			parsecViewController.requestAdaptiveResolutionIfNeeded()
		}
	}

	func changeDisplay(displayId: String) {
		DispatchQueue.main.async {
			DataManager.model.output = displayId
			CParsec.updateHostVideoConfig()
		}
	}

	static func getHostUserData() {
		let data = Data()
		CParsec.sendUserData(type: .getVideoConfig, message: data)
		CParsec.sendUserData(type: .getAdapterInfo, message: data)
	}

}

// from https://github.com/utmapp/UTM/blob/117e3a962f2f46f7d847632d65fa7a85a2bb0cfa/Platform/iOS/VMWindowView.swift#L314
private extension View {
	func prefersPersistentSystemOverlaysHidden() -> some View {
		if #available(iOS 16, *) {
			return self.persistentSystemOverlays(.hidden)
		} else {
			return self
		}
	}
}
