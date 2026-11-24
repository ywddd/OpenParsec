import SwiftUI
import UIKit

struct StreamControlActions {
	var setOpen: (Bool) -> Void
	var setCursorMode: (CursorMode) -> Void
	var toggleVirtualMouse: () -> Void
	var setVirtualMouseScale: (Double) -> Void
	var resetVirtualMousePosition: () -> Void
	var setResolution: (ParsecResolution) -> Void
	var setBitrate: (Int) -> Void
	var setDisplay: (String) -> Void
	var toggleMute: () -> Void
	var toggleViewOnly: () -> Void
	var resetView: () -> Void
	var openSettings: () -> Void
	var toggleDisplayMode: () -> Void
	var toggleZoom: () -> Void
	var toggleConstantFps: () -> Void
	var setTextInputMode: (TextInputMode) -> Void
	var rightClick: () -> Void
	var hideButtons: () -> Void
	var toggleKeyboard: () -> Void
	var toggleStreamOrientation: () -> Void
	var showDesktop: () -> Void
	var switchWindow: () -> Void
	var exit: () -> Void
}

struct StreamControlState {
	var isOpen: Bool
	var isViewOnly: Bool
	var isMuted: Bool
	var keyboardVisible: Bool
	var keyboardBottomInset: CGFloat
	var isOverlayHidden: Bool
	var streamOrientationIsLandscape: Bool
	var canRequestStreamOrientation: Bool
	var isAdaptiveDisplay: Bool
	var isPinchZoomEnabled: Bool
	var isConstantFps: Bool
	var isKeyboardButtonVisible: Bool
	var textInputMode: TextInputMode
	var displays: [ParsecDisplayConfig]
	var selectedDisplay: String
	var adaptiveStatus: String?
	var diagnosticsSummary: String?
	var fullDiagnostics: String?
}

struct StreamControlPanel: View {
	@Binding var cursorMode: CursorMode
	@Binding var virtualMouseEnabled: Bool
	@Binding var virtualMouseScale: Double
	@Binding var resolution: ParsecResolution
	@Binding var bitrate: Int
	@Binding var showFullDiagnostics: Bool

	let resolutions: [ParsecResolution]
	let bitrates: [Int]
	let state: StreamControlState
	let actions: StreamControlActions

	var body: some View {
		GeometryReader { proxy in
			let safe = proxy.safeAreaInsets
			let isLandscape = proxy.size.width > proxy.size.height
			let bottomInset = max(safe.bottom, state.keyboardBottomInset)
			let available = CGSize(
				width: max(1, proxy.size.width - safe.leading - safe.trailing),
				height: max(1, proxy.size.height - safe.top - bottomInset)
			)
			Group {
				if state.keyboardVisible && (!state.isOverlayHidden || state.isOpen) {
					keyboardActionCapsule(in: proxy, safe: safe, bottomInset: bottomInset)
				} else if state.keyboardVisible {
					collapsedKeyboardControl(in: proxy, safe: safe, bottomInset: bottomInset)
				} else if isLandscape {
					landscapeLayout(available: available, safe: safe, bottom: bottomInset)
				} else {
					portraitLayout(available: available, safe: safe, bottomInset: bottomInset)
				}
			}
			.frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottomTrailing)
		}
		.ignoresSafeArea(.container, edges: .all)
	}

	private func keyboardActionCapsule(in proxy: GeometryProxy, safe: EdgeInsets, bottomInset: CGFloat) -> some View {
		HStack(spacing: 2) {
			compactIcon("rotate.right", label: orientationButtonTitle, action: actions.toggleStreamOrientation)
			compactIcon("keyboard", label: L("stream_keyboard_hide"), action: actions.toggleKeyboard)
			compactIcon("slider.horizontal.3", label: L("stream_actions_show"), action: { actions.setOpen(true) })
		}
		.padding(4)
		.background(panelBackground)
		.fixedSize()
		.position(x: proxy.size.width - safe.trailing - 72,
				  y: max(safe.top + 28, proxy.size.height - bottomInset - 36))
	}

	private func collapsedKeyboardControl(in proxy: GeometryProxy, safe: EdgeInsets, bottomInset: CGFloat) -> some View {
		HStack(spacing: 6) {
			compactIcon("rotate.right", label: orientationButtonTitle, action: actions.toggleStreamOrientation)
			compactIcon("keyboard", label: L("stream_keyboard_hide"), action: actions.toggleKeyboard)
		}
		.padding(4)
		.background(panelBackground)
		.fixedSize()
		.position(x: proxy.size.width - safe.trailing - 52,
				  y: max(safe.top + 28, proxy.size.height - bottomInset - 36))
	}

	private var orientationButtonTitle: String {
		guard state.canRequestStreamOrientation else { return L("stream_orientation_requires_ios16") }
		return L(state.streamOrientationIsLandscape ? "stream_rotate_portrait" : "stream_rotate_landscape")
	}

	private func landscapeLayout(available: CGSize, safe: EdgeInsets, bottom: CGFloat) -> some View {
		HStack(alignment: .bottom, spacing: 0) {
			Spacer(minLength: 0)
			if state.isOpen {
				landscapePanel(maxHeight: available.height - 12, maxWidth: available.width * 0.46)
				landscapeDock
			} else {
				collapsedButton
			}
		}
		.padding(.bottom, max(12, bottom))
		.padding(.trailing, max(12, safe.trailing))
	}

	private func portraitLayout(available: CGSize, safe: EdgeInsets, bottomInset: CGFloat) -> some View {
		VStack(spacing: 0) {
			Spacer(minLength: 0)
			if state.isOpen {
				VStack(spacing: 8) {
					portraitPanel(maxHeight: available.height - 76)
					portraitDock
				}
			} else {
				HStack(spacing: 0) {
					Spacer(minLength: 0)
					collapsedButton
				}
			}
		}
		.frame(maxWidth: .infinity, alignment: .bottom)
		.padding(.horizontal, 12)
		.padding(.bottom, max(8, bottomInset))
	}

	private var collapsedButton: some View {
		HStack(spacing: 6) {
			compactIcon("rotate.right", label: orientationButtonTitle, action: actions.toggleStreamOrientation)
			Button {
				withAnimation(.easeInOut(duration: 0.2)) { actions.setOpen(true) }
			} label: {
				Image(systemName: "slider.horizontal.3")
					.font(.system(size: 20, weight: .semibold))
					.foregroundColor(.white)
					.frame(width: 48, height: 48)
					.background(Circle().fill(Color.black.opacity(0.58)))
					.overlay(Circle().stroke(Color.white.opacity(0.22), lineWidth: 1))
			}
			.accessibilityLabel(L("stream_actions_show"))
		}
	}

	private var landscapeDock: some View {
		VStack(spacing: 8) {
			if state.isKeyboardButtonVisible || state.keyboardVisible {
				dockIcon("keyboard", label: L("stream_keyboard"), active: state.keyboardVisible, action: actions.toggleKeyboard)
			}
			dockIcon("desktopcomputer", label: L("stream_show_desktop"), action: actions.showDesktop)
			dockIcon("rectangle.on.rectangle", label: L("stream_switch_window"), action: actions.switchWindow)
			dockIcon("slider.horizontal.3", label: L("stream_actions_hide"), active: true) {
				withAnimation(.easeInOut(duration: 0.2)) { actions.setOpen(false) }
			}
		}
		.padding(8)
		.background(panelBackground)
		.padding(.vertical, 8)
	}

	private var portraitDock: some View {
		HStack(spacing: 6) {
			if state.isKeyboardButtonVisible || state.keyboardVisible {
				dockIcon("keyboard", label: L("stream_keyboard"), active: state.keyboardVisible, action: actions.toggleKeyboard)
			}
			dockIcon("desktopcomputer", label: L("stream_show_desktop"), action: actions.showDesktop)
			dockIcon("rectangle.on.rectangle", label: L("stream_switch_window"), action: actions.switchWindow)
			dockIcon("slider.horizontal.3", label: L("stream_actions_hide"), active: true) {
				withAnimation(.easeInOut(duration: 0.2)) { actions.setOpen(false) }
			}
		}
		.padding(.horizontal, 8)
		.padding(.vertical, 6)
		.background(panelBackground)
		.frame(maxWidth: 380)
	}

	private func portraitPanel(maxHeight: CGFloat) -> some View {
		panelBody(horizontal: false)
			.frame(maxWidth: 380)
			.frame(height: max(1, min(520, maxHeight)))
	}

	private func landscapePanel(maxHeight: CGFloat, maxWidth: CGFloat) -> some View {
		panelBody(horizontal: true)
			.frame(width: max(220, min(320, maxWidth)))
			.frame(height: max(1, min(560, maxHeight)))
	}

	private func panelBody(horizontal: Bool) -> some View {
		VStack(spacing: 0) {
			panelHeader
			Divider().background(Color.white.opacity(0.12))
			ScrollView {
				content(horizontal: horizontal)
					.padding(.horizontal, 12)
					.padding(.vertical, 10)
			}
			Divider().background(Color.white.opacity(0.12))
			exitButton
		}
		.background(panelBackground)
	}

	private var panelHeader: some View {
		HStack(spacing: 10) {
			Text(L("stream_operations"))
				.font(.system(size: 16, weight: .semibold))
				.foregroundColor(.white)
			Spacer()
			Button {
				withAnimation(.easeInOut(duration: 0.2)) { actions.setOpen(false) }
			} label: {
				Image(systemName: "chevron.down")
					.font(.system(size: 15, weight: .semibold))
					.foregroundColor(.white.opacity(0.85))
					.frame(width: 44, height: 44)
			}
			.accessibilityLabel(L("stream_actions_hide"))
		}
		.padding(.leading, 14)
		.padding(.trailing, 2)
		.padding(.top, 4)
	}

	@ViewBuilder
	private func content(horizontal: Bool) -> some View {
		VStack(alignment: .leading, spacing: 12) {
			quickActions
			sectionTitle(L("stream_control_mode"))
			SegmentPicker(selection: Binding(
				get: { cursorMode },
				set: { actions.setCursorMode($0) }
			), options: [
				Choice(L("stream_control_screen_touch"), CursorMode.direct),
				Choice(L("stream_control_mouse_pointer"), CursorMode.touchpad)
			])
			.frame(minHeight: 36)

			sectionTitle(L("stream_pointer_controls"))
			virtualMouseCard
			if virtualMouseEnabled {
				Slider(value: Binding(
					get: { virtualMouseScale },
					set: { actions.setVirtualMouseScale($0) }
				), in: Double(VirtualMouseConfiguration.minimumScale)...Double(VirtualMouseConfiguration.maximumScale), step: 0.05) {
					Text(L("stream_virtual_mouse_size"))
						.font(.system(size: 13))
						.foregroundColor(.white.opacity(0.8))
				}
				Button(action: actions.resetVirtualMousePosition) {
					Label(L("stream_virtual_mouse_reset_position"), systemImage: "arrow.uturn.backward")
						.font(.system(size: 13, weight: .medium))
						.foregroundColor(.white.opacity(0.85))
						.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
				}
			}

			sectionTitle(L("stream_input_choices"))
			VStack(spacing: 2) {
				Menu {
					Button {
						actions.setTextInputMode(.text)
					} label: {
						if state.textInputMode == .text {
							Label(L("text_input_text"), systemImage: "checkmark")
						} else {
							Text(L("text_input_text"))
						}
					}
					Button {
						actions.setTextInputMode(.keys)
					} label: {
						if state.textInputMode == .keys {
							Label(L("text_input_keys"), systemImage: "checkmark")
						} else {
							Text(L("text_input_keys"))
						}
					}
				} label: {
					panelMenuLabel(
						icon: "text.cursor",
						title: L("text_input_mode"),
						value: L(state.textInputMode == .text ? "text_input_text" : "text_input_keys")
					)
				}
			}

			sectionTitle(L("stream_view_controls"))
			VStack(spacing: 2) {
				controlRow(icon: "rotate.right", title: orientationButtonTitle, action: actions.toggleStreamOrientation)
				controlRow(
					icon: "rectangle.inset.filled",
					title: String(format: L("display_mode_state"), L(state.isAdaptiveDisplay ? "display_fill" : "display_fit")),
					action: actions.toggleDisplayMode
				)
				controlRow(
					icon: "arrow.up.left.and.arrow.down.right",
					title: String(format: L("pinch_to_zoom_state"), L(state.isPinchZoomEnabled ? "on" : "off")),
					action: actions.toggleZoom
				)
				controlRow(
					icon: "metronome",
					title: String(format: L("constant_frame_rate_state"), L(state.isConstantFps ? "on" : "off")),
					action: actions.toggleConstantFps
				)
				controlRow(icon: "computermouse", title: L("right_click_now"), action: actions.rightClick)
				controlRow(icon: "eye.slash", title: L("hide_buttons"), action: actions.hideButtons)
			}

			sectionTitle(L("stream_resolution_bitrate"))
			if horizontal {
				HStack(spacing: 8) {
					resolutionPicker
					bitratePicker
				}
			} else {
				VStack(spacing: 8) {
					resolutionPicker
					bitratePicker
				}
			}
			if state.displays.count > 1 {
				displayPicker
			}

			if let adaptiveStatus = state.adaptiveStatus {
				sectionTitle(L("stream_adaptive_diagnostics"))
				Text(adaptiveStatus)
					.font(.system(size: 12))
					.foregroundColor(.white.opacity(0.75))
					.fixedSize(horizontal: false, vertical: true)
				if let summary = state.diagnosticsSummary {
					Text(summary)
						.font(.system(size: 11, design: .monospaced))
						.foregroundColor(.white.opacity(0.65))
						.fixedSize(horizontal: false, vertical: true)
				}
				if let full = state.fullDiagnostics {
					Button {
						withAnimation(.easeInOut(duration: 0.2)) { showFullDiagnostics.toggle() }
					} label: {
						Label(L("stream_full_diagnostics"), systemImage: showFullDiagnostics ? "chevron.up" : "chevron.down")
							.font(.system(size: 12, weight: .medium))
							.foregroundColor(.white.opacity(0.8))
							.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
					}
					if showFullDiagnostics {
						Text(full)
							.font(.system(size: 10, design: .monospaced))
							.foregroundColor(.white.opacity(0.65))
							.fixedSize(horizontal: false, vertical: true)
					}
				}
			}
		}
	}

	private var quickActions: some View {
		LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
			quickTile(
				icon: state.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
				title: L(state.isMuted ? "stream_sound_off" : "stream_sound_on"),
				tint: state.isMuted ? .orange : .white,
				action: actions.toggleMute
			)
			quickTile(
				icon: state.isViewOnly ? "eye.fill" : "eye",
				title: L("stream_view_only"),
				tint: state.isViewOnly ? Color("AccentColor") : .white,
				action: actions.toggleViewOnly
			)
			quickTile(icon: "arrow.counterclockwise", title: L("stream_reset_view"), action: actions.resetView)
			quickTile(icon: "gear", title: L("stream_settings"), action: actions.openSettings)
		}
	}

	private var virtualMouseCard: some View {
		Button(action: actions.toggleVirtualMouse) {
			HStack(spacing: 10) {
				Image(systemName: "computermouse.fill")
					.font(.system(size: 18))
					.frame(width: 28)
				VStack(alignment: .leading, spacing: 2) {
					Text(L("stream_virtual_mouse"))
						.font(.system(size: 14, weight: .medium))
					Text(L("stream_virtual_mouse_help"))
						.font(.system(size: 11))
						.foregroundColor(.white.opacity(0.6))
						.fixedSize(horizontal: false, vertical: true)
				}
				Spacer(minLength: 4)
				Toggle("", isOn: Binding(get: { virtualMouseEnabled }, set: { _ in actions.toggleVirtualMouse() }))
					.labelsHidden()
					.frame(width: 50)
					.allowsHitTesting(false)
			}
			.padding(10)
			.background(Color.white.opacity(0.08))
			.cornerRadius(10)
			.foregroundColor(.white)
		}
	}

	private var resolutionPicker: some View {
		Menu {
			ForEach(resolutions, id: \.self) { choice in
				Button {
					actions.setResolution(choice)
				} label: {
					if resolution == choice {
						Label(choice.desc, systemImage: "checkmark")
					} else {
						Text(choice.desc)
					}
				}
			}
		} label: {
			panelMenuLabel(icon: "display", title: L("resolution"), value: resolution.desc)
		}
	}

	private var bitratePicker: some View {
		Menu {
			Button {
				actions.setBitrate(0)
			} label: {
				if bitrate == 0 {
					Label(L("host_default"), systemImage: "checkmark")
				} else {
					Text(L("host_default"))
				}
			}
			ForEach(bitrates, id: \.self) { value in
				Button {
					actions.setBitrate(value)
				} label: {
					if bitrate == value {
						Label("\(value) Mbps", systemImage: "checkmark")
					} else {
						Text("\(value) Mbps")
					}
				}
			}
		} label: {
			panelMenuLabel(
				icon: "speedometer",
				title: L("bitrate"),
				value: bitrate == 0 ? L("host_default") : "\(bitrate) Mbps"
			)
		}
	}

	private var displayPicker: some View {
		Menu {
			Button {
				actions.setDisplay("none")
			} label: {
				if state.selectedDisplay == "none" {
					Label(L("auto"), systemImage: "checkmark")
				} else {
					Text(L("auto"))
				}
			}
			ForEach(state.displays, id: \.self) { config in
				Button {
					actions.setDisplay(config.id)
				} label: {
					if state.selectedDisplay == config.id {
						Label("\(config.name) \(config.adapterName)", systemImage: "checkmark")
					} else {
						Text("\(config.name) \(config.adapterName)")
					}
				}
			}
		} label: {
			panelMenuLabel(
				icon: "display.2",
				title: L("switch_display"),
				value: state.selectedDisplay == "none"
					? L("auto")
					: state.displays.first(where: { $0.id == state.selectedDisplay }).map { "\($0.name) \($0.adapterName)" } ?? L("auto")
			)
		}
	}

	private func panelMenuLabel(icon: String, title: String, value: String) -> some View {
		HStack(spacing: 10) {
			Image(systemName: icon)
				.frame(width: 24)
			VStack(alignment: .leading, spacing: 1) {
				Text(title)
					.font(.system(size: 12))
					.foregroundColor(.white.opacity(0.6))
				Text(value)
					.font(.system(size: 13, weight: .medium))
					.lineLimit(1)
			}
			Spacer(minLength: 4)
			Image(systemName: "chevron.up.chevron.down")
				.font(.system(size: 10))
				.foregroundColor(.white.opacity(0.45))
		}
		.foregroundColor(.white)
		.padding(.horizontal, 10)
		.frame(maxWidth: .infinity, minHeight: 52)
		.background(Color.white.opacity(0.08))
		.cornerRadius(10)
	}

	private func controlRow(icon: String, title: String, active: Bool = false, action: @escaping () -> Void) -> some View {
		Button(action: action) {
			HStack(spacing: 10) {
				Image(systemName: icon)
					.frame(width: 26)
				Text(title)
				Spacer()
				if active {
					Image(systemName: "checkmark")
						.font(.system(size: 13, weight: .semibold))
						.foregroundColor(Color("AccentColor"))
				}
			}
			.foregroundColor(.white)
			.frame(maxWidth: .infinity, minHeight: 44)
			.contentShape(Rectangle())
		}
	}

	private func dockIcon(_ systemName: String, label: String, active: Bool = false, action: @escaping () -> Void) -> some View {
		Button(action: action) {
			Image(systemName: systemName)
				.font(.system(size: 18, weight: .medium))
				.foregroundColor(active ? Color("AccentColor") : .white)
				.frame(width: 44, height: 44)
				.background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(active ? 0.16 : 0.06)))
		}
		.accessibilityLabel(label)
	}

	private func compactIcon(_ systemName: String, label: String, action: @escaping () -> Void) -> some View {
		Button(action: action) {
			Image(systemName: systemName)
				.font(.system(size: 17, weight: .medium))
				.foregroundColor(.white)
				.frame(width: 44, height: 44)
		}
		.accessibilityLabel(label)
	}

	private func quickTile(icon: String, title: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
		Button(action: action) {
			HStack(spacing: 8) {
				Image(systemName: icon)
					.font(.system(size: 16, weight: .medium))
				Text(title)
					.font(.system(size: 13, weight: .medium))
					.lineLimit(1)
					.minimumScaleFactor(0.8)
			}
			.foregroundColor(tint)
			.frame(maxWidth: .infinity, minHeight: 48)
			.background(Color.white.opacity(0.08))
			.cornerRadius(10)
		}
	}

	private var exitButton: some View {
		Button(action: actions.exit) {
			HStack(spacing: 8) {
				Image(systemName: "rectangle.portrait.and.arrow.right")
				Text(L("stream_exit"))
			}
			.font(.system(size: 14, weight: .semibold))
			.foregroundColor(.red)
			.frame(maxWidth: .infinity, minHeight: 48)
			.contentShape(Rectangle())
		}
		.padding(.horizontal, 8)
		.padding(.bottom, 4)
	}

	private func sectionTitle(_ text: String) -> some View {
		Text(text)
			.font(.system(size: 12, weight: .semibold))
			.foregroundColor(.white.opacity(0.55))
			.textCase(.uppercase)
			.padding(.top, 2)
	}

	private var panelBackground: some View {
		RoundedRectangle(cornerRadius: 18, style: .continuous)
			.fill(Color.black.opacity(0.82))
			.overlay(
				RoundedRectangle(cornerRadius: 18, style: .continuous)
					.stroke(Color.white.opacity(0.12), lineWidth: 1)
			)
	}
}
