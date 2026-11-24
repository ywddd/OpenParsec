import ParsecSDK
import UIKit

class TouchController {

	func onTouch(typeOfTap: Int, location: CGPoint, state: UIGestureRecognizer.State) {
		// Send the mouse input to the host
		let parsecTap = ParsecMouseButton(rawValue: UInt32(typeOfTap))
		switch state {
			case .began:
				CParsec.sendMouseMessage(parsecTap, viewportPoint: location, true)
			case .changed:
				CParsec.sendMousePosition(viewportPoint: location)
			case .ended, .cancelled:
				CParsec.sendMouseMessage(parsecTap, viewportPoint: location, false)
			default:
				break
		}
	}

	func onTap(typeOfTap: Int, location: CGPoint) {

		let parsecTap = ParsecMouseButton(rawValue: UInt32(typeOfTap))

		// send press+release back-to-back. the old 20ms async release could be orphaned by a
		// reconnect/disconnect landing in that window, leaving the button (esp. right) stuck on the
		// host — which pops a context menu that survives the transition.
		if SettingsHandler.cursorMode == .direct {
			CParsec.sendMouseMessage(parsecTap, viewportPoint: location, true)
			CParsec.sendMouseMessage(parsecTap, viewportPoint: location, false)

		} else {
			CParsec.sendMouseClickMessage(parsecTap, true)
			CParsec.sendMouseClickMessage(parsecTap, false)
		}
	}

	public func viewDidLoad() { }

}
