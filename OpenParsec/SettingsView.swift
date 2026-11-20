import SwiftUI

struct SettingsView: View {
	@Binding var visible: Bool
	@ObservedObject private var settings = SettingsStore.shared

	let resolutionChoices: [Choice<ParsecResolution>]

	init(visible: Binding<Bool>) {
		_visible = visible
		var tmp: [Choice<ParsecResolution>] = []
		for res in ParsecResolution.resolutions {
			tmp.append(Choice(res.desc, res))
		}
		resolutionChoices = tmp
	}

	var body: some View {
		ZStack {
			if visible {
				// Background
				Rectangle()
					.fill(Color.init(red: 0, green: 0, blue: 0, opacity: 0.67))
					.edgesIgnoringSafeArea(.all)
			}
		}

		ZStack {
			if visible {
				// Main controls
				VStack {
					// Navigation controls
					ZStack {
						Rectangle()
							.fill(Color("BackgroundTab"))
							.frame(height: 52)
							.shadow(color: Color("Shading"), radius: 4, y: 6)
						ZStack {
							HStack {
								Button(action: saveAndExit, label: { Image(systemName: "xmark").scaleEffect(x: -1) })
								 .padding()
								Spacer()
							}
							Text(L("settings"))
								.multilineTextAlignment(.center)
								.foregroundColor(Color("Foreground"))
								.font(.system(size: 20, weight: .medium))
							Spacer()
						}
						.foregroundColor(Color("AccentColor"))
					}
					.zIndex(1)

					ScrollView {
						VStack {
							CatTitle(L("touch_and_mouse"))
							CatList {
								CatItem(L("touch_mode")) {
									MultiPicker(selection: $settings.cursorMode, options:
									[
										Choice(L("touchpad"), CursorMode.touchpad),
										Choice(L("direct"), CursorMode.direct)
									])
								}
								CatItem(L("right_click")) {
									MultiPicker(selection: $settings.rightClickPosition, options:
									[
										Choice(L("first_finger"), RightClickPosition.firstFinger),
										Choice(L("middle"), RightClickPosition.middle),
										Choice(L("second_finger"), RightClickPosition.secondFinger)
									])
								}
								CatSlider(L("pointer_speed"), value: $settings.mouseSensitivity, in: 0.1...4, step: 0.1)
								CatSlider(L("cursor_size"), value: $settings.cursorScale, in: 0.1...4, step: 0.1)
								CatSlider(L("scroll_speed"), value: $settings.scrollSensitivity, in: 0.5...5, step: 0.5)
								CatItem(L("reverse_scrolling")) {
									Toggle("", isOn: $settings.reverseScrollDirection)
										.frame(width: 80)
								}
								CatItem(L("pinch_to_zoom")) {
									Toggle("", isOn: $settings.zoomEnabled)
										.frame(width: 80)
								}
							}
							CatTitle(L("keyboard"))
							CatList {
								CatItem(L("show_keyboard_button")) {
									Toggle("", isOn: $settings.showKeyboardButton)
										.frame(width: 80)
								}
								CatItem(L("option_as_command")) {
									Toggle("", isOn: $settings.optionAsCommand)
										.frame(width: 80)
								}
							}
							CatTitle(L("video"))
							CatList {
								CatItem(L("display_mode")) {
									SegmentPicker(selection: $settings.streamDisplayMode, options: [
										Choice(L("display_fill"), StreamDisplayMode.fill),
										Choice(L("display_fit"), StreamDisplayMode.fit)
									])
									.frame(width: 165)
								}
								CatItem(L("renderer")) {
									SegmentPicker(selection: $settings.renderer, options: [
										Choice("OpenGL", RendererType.opengl),
										Choice("Metal", RendererType.metal)
									])
									.frame(width: 165)
								}
								CatItem(L("resolution")) {
									MultiPicker(selection: $settings.resolution, options: resolutionChoices)
								}
								CatItem(L("bitrate")) {
									MultiPicker(selection: $settings.bitrate, options: [Choice(L("host_default"), 0)] + ParsecResolution.bitrates.map { Choice("\($0) Mbps", $0) })
								}
								CatItem(L("frame_rate")) {
									MultiPicker(selection: $settings.preferredFramesPerSecond, options:
									[
										Choice(L("auto_device_max"), 0),
										Choice("120 FPS", 120),
										Choice("60 FPS", 60),
										Choice("30 FPS", 30)
									])
								}
								CatItem(L("constant_frame_rate")) {
									Toggle("", isOn: $settings.constantFps)
										.frame(width: 80)
								}
								CatItem(L("codec")) {
									MultiPicker(selection: $settings.decoder, options:
									[
										Choice("H.264", DecoderPref.h264),
										Choice(L("prefer_h265"), DecoderPref.h265)
									])
								}
							}
							CatTitle(L("during_stream"))
							CatList {
								CatItem(L("show_stream_stats")) {
									Toggle("", isOn: $settings.alwaysShowStatus)
										.frame(width: 80)
								}
								CatItem(L("show_menu_button")) {
									Toggle("", isOn: Binding(get: { !settings.noOverlay }, set: { settings.noOverlay = !$0 }))
										.frame(width: 80)
								}
								CatItem(L("menu_edge_swipe")) {
									MultiPicker(selection: $settings.menuSwipeEdge, options:
									[
										Choice(L("off"), MenuSwipeEdge.off),
										Choice(L("left_edge"), MenuSwipeEdge.left),
										Choice(L("right_edge"), MenuSwipeEdge.right)
									])
								}
								CatItem(UIDevice.current.userInterfaceIdiom == .pad ? L("hide_ipad_status_bar") : L("hide_iphone_status_bar")) {
									Toggle("", isOn: $settings.hideStatusBar)
										.frame(width: 80)
								}
								CatItem(L("picture_in_picture")) {
									Toggle("", isOn: $settings.enablePiP)
										.frame(width: 80)
								}
								CatItem(L("start_muted")) {
									Toggle("", isOn: $settings.startMuted)
										.frame(width: 80)
								}
								CatItem(L("sync_clipboard")) {
									Toggle("", isOn: $settings.clipboardSync)
										.frame(width: 80)
								}
							}
							CatTitle(L("developer"))
							CatList {
								CatItem(L("auto_reconnect")) {
									Toggle("", isOn: $settings.autoReconnect)
										.frame(width: 80)
								}
								if settings.autoReconnect {
									CatItem(L("show_reconnect_errors")) {
										Toggle("", isOn: $settings.errorPrompts)
											.frame(width: 80)
									}
								}
								CatItem(L("show_connection_log")) {
									Toggle("", isOn: $settings.showConnectionLog)
										.frame(width: 80)
								}
							}
							Text(getVersionInfo())
								.multilineTextAlignment(.center)
								.opacity(0.5)
								.padding()
						}
					}
                    .foregroundColor(Color("Foreground"))
				}
				.background(Rectangle().fill(Color("BackgroundGray")))
				.cornerRadius(8)
				.padding()
			}
		}
        .preferredColorScheme(appScheme)
		.scaleEffect(visible ? 1 : 0, anchor: .zero)
	}

	func saveAndExit() {
		// SettingsHandler.renderer = renderer
		withAnimation(.easeInOut(duration: 0.24)) {
			visible = false
		}
	}

	func getVersionInfo() -> String {
		let info = Bundle.main.infoDictionary
		let version = info?["CFBundleShortVersionString"] as? String ?? L("unknown_version")
		let commit = info?["GitCommitInfo"] as? String ?? L("unknown_commit")
		return String(format: L("version_info"), version, commit)
	}
}

struct SettingsView_Previews: PreviewProvider {
	@State static var value: Bool = true

	static var previews: some View {
		SettingsView(visible: $value)
	}
}
