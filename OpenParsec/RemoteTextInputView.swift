import UIKit

final class RemoteTextInputView: UITextView, UITextViewDelegate {
	var onCommittedText: ((String) -> Void)?
	var onDeleteBackward: (() -> Void)?
	var onCompositionChanged: ((String) -> Void)?

	private var resetting = false
	private var lastComposition = ""

	init() {
		super.init(frame: .zero, textContainer: nil)
		delegate = self
		backgroundColor = .clear
		textColor = .clear
		tintColor = .clear
		isOpaque = false
		isScrollEnabled = false
		autocorrectionType = .no
		spellCheckingType = .no
		smartQuotesType = .no
		smartDashesType = .no
		smartInsertDeleteType = .no
		autocapitalizationType = .none
		textContainerInset = .zero
		textContainer.lineFragmentPadding = 0
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override var canBecomeFirstResponder: Bool {
		true
	}

	override func resignFirstResponder() -> Bool {
		resetComposition()
		return super.resignFirstResponder()
	}

	static func isTextProducingKey(_ key: UIKey) -> Bool {
		guard key.modifierFlags.intersection([.command, .control, .alternate]).isEmpty else { return false }
		let usage = Int(key.keyCode.rawValue)
		return (20...56).contains(usage) || (87...99).contains(usage)
	}

	func resetComposition() {
		let hadComposition = markedTextRange != nil || lastComposition.isEmpty == false
		resetting = true
		if markedTextRange != nil {
			unmarkText()
		}
		text = ""
		resetting = false
		lastComposition = ""
		if hadComposition {
			onCompositionChanged?("")
		}
	}

	func textViewDidChange(_ textView: UITextView) {
		guard resetting == false else { return }
		if let markedRange = markedTextRange {
			let composition = text(in: markedRange) ?? ""
			guard composition != lastComposition else { return }
			lastComposition = composition
			onCompositionChanged?(composition)
			return
		}
		if lastComposition.isEmpty == false {
			lastComposition = ""
			onCompositionChanged?("")
		}
		let committed = text ?? ""
		guard committed.isEmpty == false else { return }
		resetting = true
		text = ""
		resetting = false
		onCommittedText?(committed)
	}

	override func deleteBackward() {
		if markedTextRange != nil {
			super.deleteBackward()
			return
		}
		if text?.isEmpty == false {
			resetting = true
			text = ""
			resetting = false
		}
		onDeleteBackward?()
	}
}
