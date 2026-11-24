import Foundation

enum TextInputMode: Int, Codable, Hashable {
	case text = 0
	case keys = 1
}

enum TextPasteShortcut: Int, Codable, Hashable {
	case controlV = 0
	case commandV = 1
}

struct RemotePasteChord: Equatable {
	let modifierKeyCode: UInt32
	let keyCode: UInt32

	init(modifierKeyCode: UInt32, keyCode: UInt32) {
		self.modifierKeyCode = modifierKeyCode
		self.keyCode = keyCode
	}
}

enum RemoteInputAction: Equatable {
	case pasteText(String)
	case keyPress(String)
}

struct RemoteInputPlan: Equatable {
	let actions: [RemoteInputAction]
	let shortcut: TextPasteShortcut

	init(actions: [RemoteInputAction], shortcut: TextPasteShortcut) {
		self.actions = actions
		self.shortcut = shortcut
	}

	var pasteChunks: [String] {
		actions.compactMap {
			if case .pasteText(let text) = $0 {
				return text
			}
			return nil
		}
	}

	var requiresClipboard: Bool {
		pasteChunks.isEmpty == false
	}
}

enum RemoteInputPlanError: Error, Equatable {
	case tooLong
	case unsupportedUnicode
}

enum RemoteInputPolicy {
	static let maxChunkBytes = 32 * 1024
	static let maxTextBytes = 1 << 20
	static let namedKeys: Set<String> = [
		"ENTER", "BACKSPACE", "TAB", "SPACE", "UIKeyInputEscape", "ESCAPE",
		"SHIFT", "CONTROL", "LALT", "LGUI", "RCTRL", "RSHIFT", "RALT", "RGUI",
		"DELETE", "INSERT", "HOME", "END", "PAGEUP", "PAGEDOWN", "UP", "DOWN", "LEFT", "RIGHT",
		"F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12"
	]

	static func makePlan(
		text: String,
		mode: TextInputMode,
		shortcut: TextPasteShortcut
	) -> Result<RemoteInputPlan, RemoteInputPlanError> {
		guard text.unicodeScalars.contains(where: { $0.value == 0 }) == false else {
			return .failure(.unsupportedUnicode)
		}
		guard text.utf8.count <= maxTextBytes else {
			return .failure(.tooLong)
		}
		switch mode {
		case .text:
			var actions: [RemoteInputAction] = []
			var buffer = ""
			func flushBuffer() -> RemoteInputPlanError? {
				guard buffer.isEmpty == false else { return nil }
				switch utf8Chunks(of: buffer) {
				case .success(let chunks):
					actions.append(contentsOf: chunks.map { .pasteText($0) })
					buffer = ""
					return nil
				case .failure(let error):
					return error
				}
			}
			for character in text {
				if character == "\r\n" || character == "\n" || character == "\r" {
					if let error = flushBuffer() { return .failure(error) }
					actions.append(.keyPress("ENTER"))
				} else if character == "\t" {
					if let error = flushBuffer() { return .failure(error) }
					actions.append(.keyPress("TAB"))
				} else {
					buffer.append(character)
				}
			}
			if let error = flushBuffer() { return .failure(error) }
			return .success(RemoteInputPlan(actions: actions, shortcut: shortcut))
		case .keys:
			guard let names = keyNames(for: text) else {
				return .failure(.unsupportedUnicode)
			}
			return .success(RemoteInputPlan(actions: names.map { .keyPress($0) }, shortcut: shortcut))
		}
	}

	static func makeNamedKeyPlan(
		key: String,
		shortcut: TextPasteShortcut
	) -> Result<RemoteInputPlan, RemoteInputPlanError> {
		guard namedKeys.contains(key) else {
			return .failure(.unsupportedUnicode)
		}
		return .success(RemoteInputPlan(actions: [.keyPress(key)], shortcut: shortcut))
	}

	static func utf8Chunks(of text: String, maxBytes: Int = maxChunkBytes) -> Result<[String], RemoteInputPlanError> {
		let limit = max(1, maxBytes)
		var chunks: [String] = []
		var current = ""
		var currentBytes = 0
		for character in text {
			let piece = String(character)
			let pieceBytes = piece.utf8.count
			guard pieceBytes <= limit else { return .failure(.tooLong) }
			if currentBytes > 0 && currentBytes + pieceBytes > limit {
				chunks.append(current)
				current = ""
				currentBytes = 0
			}
			current += piece
			currentBytes += pieceBytes
		}
		if current.isEmpty == false {
			chunks.append(current)
		}
		return .success(chunks)
	}

	static func keyNames(for text: String) -> [String]? {
		var names: [String] = []
		for character in text {
			if character == "\r\n" || character == "\n" || character == "\r" {
				names.append("ENTER")
				continue
			}
			if character == "\t" {
				names.append("TAB")
				continue
			}
			let scalars = character.unicodeScalars
			guard scalars.count == 1, let scalar = scalars.first,
				  scalar.value >= 0x20, scalar.value < 0x7F else {
				return nil
			}
			names.append(String(character))
		}
		return names
	}

	static func pasteChord(for shortcut: TextPasteShortcut) -> RemotePasteChord {
		switch shortcut {
		case .controlV:
			return RemotePasteChord(modifierKeyCode: 224, keyCode: 25)
		case .commandV:
			return RemotePasteChord(modifierKeyCode: 227, keyCode: 25)
		}
	}
}
