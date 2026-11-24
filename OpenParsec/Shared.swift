import Foundation
import SwiftUI
import ParsecSDK
import os

var appScheme: ColorScheme = .dark

struct GLBData {
	let SessionKeyChainKey = "OPStoredAuthData"
}

class GLBDataModel {
	static let shared = GLBData()
}

extension String {
	static func fromBuffer(_ ptr: UnsafeMutablePointer<CChar>, length len: Int) -> String {
		// convert C char bytes using the UTF8 encoding
		let nsstr = NSString(bytes: ptr, length: len, encoding: NSUTF8StringEncoding)
		return nsstr! as String
	}
}

class CursorPositionHelper {
	private static var geometry: StreamGeometry {
		StreamGeometry(
			viewportSize: CGSize(width: CGFloat(CParsec.clientWidth), height: CGFloat(CParsec.clientHeight)),
			hostSize: CGSize(width: CGFloat(CParsec.hostWidth), height: CGFloat(CParsec.hostHeight)),
			mode: SettingsHandler.streamDisplayMode
		)
	}

	static func toHost(_ xp: Int, _ yp: Int) -> (Int, Int) {
		let hostPoint = geometry.hostPoint(forScreenPoint: CGPoint(x: CGFloat(xp), y: CGFloat(yp)))
		return (Int(ParsecSDKBridge.clamp(Float(hostPoint.x), minValue: 0, maxValue: CParsec.hostWidth)),
				Int(ParsecSDKBridge.clamp(Float(hostPoint.y), minValue: 0, maxValue: CParsec.hostHeight)))
	}

	static func toClient(_ xa: Int, _ ya: Int) -> (Int, Int) {
		let screenPoint = geometry.screenPoint(forHostPoint: CGPoint(x: CGFloat(xa), y: CGFloat(ya)))
		return (Int(ParsecSDKBridge.clamp(Float(screenPoint.x), minValue: 0, maxValue: CParsec.clientWidth)),
				Int(ParsecSDKBridge.clamp(Float(screenPoint.y), minValue: 0, maxValue: CParsec.clientHeight)))
	}
}

class SharedModel: ObservableObject {
	@Published var resolutionX = 0
	@Published var resolutionY = 0
	@Published var bitrate = 0
	@Published var hostDefaultBitrate = 0
	@Published var constantFps = false
	@Published var output = "none"
	@Published var displayConfigs: [ParsecDisplayConfig] = []
	@Published var isBlocked = false

	func reset() {
		resolutionX = 0
		resolutionY = 0
		bitrate = 0
		hostDefaultBitrate = 0
		constantFps = false
		output = "none"
		displayConfigs = []
		isBlocked = false
	}
}

class DataManager {
	static let model = SharedModel()
}

extension ParsecStatus {
	var isPeerConnectionFailure: Bool {
		self == NAT_ERR_PEER_PHASE || self == NAT_ERR_NO_CANDIDATES || self == NAT_ERR_STUN_PHASE
	}

	var isLocalNetworkFailure: Bool {
		self == NAT_ERR_PEER_PHASE || self == NAT_ERR_NO_CANDIDATES
	}

	func connectionMessage(connecting: Bool = false) -> String {
		let text = readable(connecting: connecting)
		let message = String(format: L("status_message"), text, rawValue)
		guard connecting && isLocalNetworkFailure else { return message }
		return message + "\n\n" + L("network_help")
	}
	func readable(connecting: Bool = false) -> String {
		switch self {
		case WS_ERR_AUTH:               return L("status_ws_err_auth")
		case WS_ERR_CONNECT:            return L("status_ws_err_connect")
		case WS_ERR_TEAM_DEACTIVATED:   return L("status_ws_err_team_deactivated")
		case NAT_ERR_PEER_PHASE:        return L("status_nat_err_peer_phase")
		case NETWORK_ERR_BG_TIMEOUT:    return L("status_network_err_bg_timeout")
		case NETWORK_ERR_UNSUPPORTED:   return L("status_network_err_unsupported")
		case CONNECT_WRN_DECLINED:      return L("status_connect_wrn_declined")
		case CONNECT_WRN_NO_PERMISSION: return L("status_connect_wrn_no_permission")
		case CONNECT_WRN_NO_ROOM:       return L("status_connect_wrn_no_room")
		case CONNECT_WRN_CANCELED:      return L("status_connect_wrn_canceled")
		case CONNECT_WRN_PEER_GONE:     return L("status_connect_wrn_peer_gone")
		case HOST_WRN_KICKED:           return L("status_host_wrn_kicked")
		case HOST_WRN_SHUTDOWN:         return L("status_host_wrn_shutdown")
		case SERVER_ERR_DISPLAY:        return L("status_server_err_display")
		case SERVER_ERR_RESOLUTION:     return L("status_server_err_resolution")
		case CAPTURE_ERR_INIT:          return L("status_capture_err_init")
		case CONNECT_WRN_APPROVAL:      return L("status_connect_wrn_approval")
		case CONNECT_WRN_UNCONFIRMED:   return L("status_connect_wrn_unconfirmed")
		case PARSEC_CONNECTING:         return L("status_parsec_connecting")
		case PARSEC_NOT_RUNNING:        return L("status_parsec_not_running")
		case NETWORK_WRN_TIMEOUT:       return L("status_network_wrn_timeout")
		case NETWORK_ERR_SHUTDOWN:      return L("status_network_err_shutdown")
		case NETWORK_ERR_INTERRUPTED:   return L("status_network_err_interrupted")
		case WS_ERR_GOING_AWAY, WS_ERR_CLOSE: return L("status_ws_err_going_away")
		case WS_ERR_READ, WS_ERR_WRITE: return L("status_ws_err_read")
		case NAT_ERR_NO_CANDIDATES:     return L("status_nat_err_no_candidates")
		case NAT_ERR_STUN_PHASE:        return L("status_nat_err_stun_phase")
		case SERVER_ERR_NO_USER:        return L("status_server_err_no_user")
		case SERVER_ERR_MAX_RESOLUTION: return L("status_server_err_max_resolution")
		case SERVER_ERR_CLIENT_GONE, SERVER_ERR_CLIENT_ABORT: return L("status_server_err_client_gone")
		default:
			os_log("%{public}@", "[status] no text for \(rawValue)")
			return String(format: L("status_message"), L(connecting ? "status_connect_failed" : "status_disconnected"), rawValue)
		}
	}

	var isPermanentFailure: Bool {
		switch self {
		case WS_ERR_AUTH, WS_ERR_TEAM_DEACTIVATED,
			 CONNECT_WRN_DECLINED, CONNECT_WRN_NO_PERMISSION, CONNECT_WRN_NO_ROOM,
			 CONNECT_WRN_CANCELED,
			 HOST_WRN_KICKED, HOST_WRN_SHUTDOWN,
			 NETWORK_ERR_UNSUPPORTED, SERVER_ERR_DISPLAY, SERVER_ERR_RESOLUTION,
			 CONNECT_WRN_UNCONFIRMED, SERVER_ERR_NO_USER, CONNECT_WRN_APPROVAL:
			return true
		default:
			return false
		}
	}
}
