import UIKit
import SwiftUI

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
	var window: UIWindow?
	private var streamOrientationMask: UIInterfaceOrientationMask?
	private var requestedStreamOrientation: UIInterfaceOrientationMask?
	private var orientationRequestGeneration = 0
	private var restorePortraitPending = false
	var onStreamOrientationChange: ((Bool) -> Void)?

	var supportedInterfaceOrientations: UIInterfaceOrientationMask {
		streamOrientationMask ?? (UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown)
	}

	var isStreamOrientationRequestPending: Bool {
		requestedStreamOrientation != nil
	}

	func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
		if connectionOptions.shortcutItem?.type == ParsecBackgroundManager.reconnectShortcut {
			ParsecBackgroundManager.shared.reconnectPending = true
		}
		ParsecBackgroundManager.shared.updateShortcut()
		let contentView = ContentView()

		if let windowScene = scene as? UIWindowScene {
		    let window = UIWindow(windowScene: windowScene)
		    window.rootViewController = OpenParsecHostingController(rootView: contentView)
		    self.window = window
		    window.makeKeyAndVisible()
		}
	}

	func requestStreamOrientation(isLandscape: Bool, onFailure: @escaping () -> Void) {
		guard #available(iOS 16.0, *), let windowScene = window?.windowScene else {
			onFailure()
			return
		}
		guard !isStreamOrientationRequestPending else { return }

		let requestedMask: UIInterfaceOrientationMask = isLandscape ? .landscape : .portrait
		let previousMask = streamOrientationMask
		orientationRequestGeneration += 1
		let requestGeneration = orientationRequestGeneration
		restorePortraitPending = false
		streamOrientationMask = requestedMask
		requestedStreamOrientation = requestedMask
		window?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
		if requestedMask == currentOrientationMask(in: windowScene) {
			requestedStreamOrientation = nil
			onStreamOrientationChange?(windowScene.interfaceOrientation.isLandscape)
			return
		}
		windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: requestedMask)) { [weak self] _ in
			DispatchQueue.main.async {
				guard let self = self,
					  self.orientationRequestGeneration == requestGeneration,
					  self.requestedStreamOrientation == requestedMask else { return }
				self.streamOrientationMask = previousMask
				self.requestedStreamOrientation = nil
				self.window?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
				self.onStreamOrientationChange?(windowScene.interfaceOrientation.isLandscape)
				onFailure()
			}
		}
	}

	func windowScene(_ windowScene: UIWindowScene, didUpdate previousCoordinateSpace: UICoordinateSpace, interfaceOrientation previousInterfaceOrientation: UIInterfaceOrientation, traitCollection: UITraitCollection) {
		let currentOrientation = windowScene.interfaceOrientation
		onStreamOrientationChange?(currentOrientation.isLandscape)
		if restorePortraitPending {
			guard currentOrientation != .portrait else { return }
			if #available(iOS 16.0, *) {
				windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
			}
			return
		}
		guard let requested = requestedStreamOrientation else { return }
		let requestMatched = requested == .landscape
			? currentOrientation.isLandscape
			: currentOrientation == .portrait
		guard requestMatched else { return }
		requestedStreamOrientation = nil
	}

	private func currentOrientationMask(in windowScene: UIWindowScene) -> UIInterfaceOrientationMask {
		switch windowScene.interfaceOrientation {
		case .portrait: return .portrait
		case .landscapeLeft, .landscapeRight: return .landscape
		case .portraitUpsideDown: return .portraitUpsideDown
		default: return UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
		}
	}

	func restorePortraitAfterStream() {
		let hadPendingRequest = isStreamOrientationRequestPending
		orientationRequestGeneration += 1
		let restoreGeneration = orientationRequestGeneration
		restorePortraitPending = hadPendingRequest || window?.windowScene?.interfaceOrientation.isLandscape == true
		streamOrientationMask = restorePortraitPending ? .portrait : nil
		requestedStreamOrientation = nil
		onStreamOrientationChange = nil
		if #available(iOS 16.0, *) {
			window?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
			window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
		}
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
			guard let self = self, self.orientationRequestGeneration == restoreGeneration else { return }
			self.restorePortraitPending = false
			self.streamOrientationMask = nil
			if #available(iOS 16.0, *) {
				self.window?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
			}
		}
	}

	func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
		guard shortcutItem.type == ParsecBackgroundManager.reconnectShortcut, !ParsecBackgroundManager.shared.hasActiveConnection, !ParsecBackgroundManager.shared.isMarkedForReconnect, let reconnect = ParsecBackgroundManager.shared.onShortcutReconnect else {
			completionHandler(false)
			return
		}
		reconnect()
		completionHandler(true)
	}

	func sceneDidDisconnect(_ scene: UIScene) {
		restorePortraitAfterStream()
		if ParsecBackgroundManager.shared.hasActiveConnection {
			CParsec.sendReleaseMessage()
			CParsec.disconnect()
		}
	}

	private var pendingUnpause: DispatchWorkItem?

	func sceneDidBecomeActive(_ scene: UIScene) {
		if #available(iOS 15.0, *) {
			PictureInPictureManager.shared.stopPiP()
			if PictureInPictureManager.shared.stopFramePump() {
				ParsecBackgroundManager.shared.glkViewController?.isPaused = false
			}
		}
		if ParsecBackgroundManager.shared.isPaused {
			ParsecBackgroundManager.shared.glkViewController?.isPaused = false
			CParsec.resume()
			ParsecBackgroundManager.shared.resumedAt = Date()
			pendingUnpause?.cancel()
			let unpause = DispatchWorkItem { ParsecBackgroundManager.shared.isPaused = false }
			pendingUnpause = unpause
			DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: unpause)
		}
		// drop any input the host still thinks is held, a stuck modifier survives the resume
		if ParsecBackgroundManager.shared.hasActiveConnection {
			CParsec.sendReleaseMessage()
		}
		ParsecBackgroundManager.shared.sceneDidBecomeActive()
	}

	func sceneWillResignActive(_ scene: UIScene) {
		if ParsecBackgroundManager.shared.hasActiveConnection {
			CParsec.sendReleaseMessage()
		}
		ParsecBackgroundManager.shared.sceneWillResignActive()
	}

	func sceneWillEnterForeground(_ scene: UIScene) {
		ParsecBackgroundManager.shared.sceneWillEnterForeground()
	}

	func sceneDidEnterBackground(_ scene: UIScene) {
		pendingUnpause?.cancel()
		pendingUnpause = nil
		var pipAttempted = false
		if #available(iOS 15.0, *) {
			if ParsecBackgroundManager.shared.hasActiveConnection && SettingsHandler.enablePiP {
				PictureInPictureManager.shared.startPiP()
				pipAttempted = PictureInPictureManager.shared.isPiPActive || PictureInPictureManager.shared.isStarting
			}
		}

		if pipAttempted {
			ParsecBackgroundManager.shared.isPaused = false
			if #available(iOS 15.0, *) {
				ParsecBackgroundManager.shared.glkViewController?.isPaused = true
				PictureInPictureManager.shared.startFramePump()
			}
		}

		if !pipAttempted && ParsecBackgroundManager.shared.hasActiveConnection {
			ParsecBackgroundManager.shared.glkViewController?.isPaused = true
			CParsec.sendReleaseMessage()
			CParsec.pause()
			ParsecBackgroundManager.shared.isPaused = true
			ParsecBackgroundManager.shared.holdSessionInBackground()
		}

		if ParsecBackgroundManager.shared.hasActiveConnection {
			appNote("[background] picture in picture \(pipAttempted ? "starting" : "off"), stream \(pipAttempted ? "running" : "paused")")
		}
		ParsecBackgroundManager.shared.sceneDidEnterBackground()
	}
}

private final class OpenParsecHostingController: UIHostingController<ContentView> {
	override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
		(view.window?.windowScene?.delegate as? SceneDelegate)?.supportedInterfaceOrientations
			?? (UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown)
	}
}
