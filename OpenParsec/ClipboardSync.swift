import UIKit
import ParsecSDK
import os

// Mirrors text between UIPasteboard and the host over user data ID 7, which the stock host
// handles in both directions when its app_copy_paste setting allows it.
final class ClipboardSync {
	static let shared = ClipboardSync()

	// The SDK warns that its message channel is not meant for bulk data.
	private let maxTextBytes = 1 << 20
	private let pollInterval: TimeInterval = 1
	private var timer: Timer?
	private var textTransactionDepth = 0
	private var expectedTextEchoes: [String] = []
	private var expectedEchoExpiry: Date?

	// Persisted so a copy made before launching the app still reaches the host, while an
	// unchanged pasteboard does not overwrite the host clipboard on every connection.
	private var lastChangeCount = UserDefaults.standard.integer(forKey: "lastClipboardChangeCount") {
		didSet { UserDefaults.standard.set(lastChangeCount, forKey: "lastClipboardChangeCount") }
	}

	func start() {
		stop()
		// Polling because UIPasteboard.changedNotification misses copies made in other apps.
		timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
			self?.sendIfChanged()
		}
		sendIfChanged()
	}

	func stop() {
		timer?.invalidate()
		timer = nil
	}

	func beginTextTransaction() {
		textTransactionDepth = 1
	}

	func expectTextEcho(_ text: String) {
		expectedTextEchoes.append(text)
		if expectedTextEchoes.count > 16 {
			expectedTextEchoes.removeFirst(expectedTextEchoes.count - 16)
		}
		expectedEchoExpiry = Date().addingTimeInterval(5)
	}

	func endTextTransaction() {
		textTransactionDepth = 0
	}

	func receive(_ text: String) {
		// Off by default because the host would otherwise overwrite the local clipboard.
		guard SettingsHandler.clipboardSync else { return }
		DispatchQueue.main.async {
			guard !self.isTextTransactionActive, !self.consumeExpectedEcho(text) else { return }
			UIPasteboard.general.string = text
			self.lastChangeCount = UIPasteboard.general.changeCount
		}
	}

	private var isTextTransactionActive: Bool {
		textTransactionDepth > 0
	}

	private func consumeExpectedEcho(_ text: String) -> Bool {
		if let expiry = expectedEchoExpiry, expiry < Date() {
			expectedTextEchoes.removeAll()
			expectedEchoExpiry = nil
			return false
		}
		guard let index = expectedTextEchoes.firstIndex(of: text) else { return false }
		expectedTextEchoes.remove(at: index)
		return true
	}

	private func sendIfChanged() {
		guard SettingsHandler.clipboardSync else { return }
		guard !isTextTransactionActive else { return }
		let pasteboard = UIPasteboard.general
		guard pasteboard.changeCount != lastChangeCount,
			UIApplication.shared.applicationState == .active,
			CParsec.getStatus() == PARSEC_OK else { return }

		// Mark it seen before reading, so a declined paste prompt is not repeated every poll.
		lastChangeCount = pasteboard.changeCount
		guard pasteboard.hasStrings, let text = pasteboard.string else { return }

		let data = Data(text.utf8)
		guard data.count <= maxTextBytes else {
			os_log("%{public}@", log: sdkLog, "[clipboard] skipped \(data.count) bytes")
			return
		}
		CParsec.sendUserData(type: .clipboard, message: data)
	}
}
