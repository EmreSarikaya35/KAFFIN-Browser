import AppKit
import BrowserCore
import SwiftUI

/// AppKit-backed so Enter and Escape can be intercepted. Omnibox completion builds on this in Phase 2.
struct AddressField: NSViewRepresentable {
    let text: String
    let placeholder: String
    let focusRequest: Int
    let onSubmit: (String) -> Void
    let inlineCompletion: InlineCompletion?
    /// Passes the text, and whether it grew. Completing after a deletion would undo the deletion.
    let onEdit: (String, Bool) -> Void
    let onMoveSelection: (Int) -> Void
    let onEndEditing: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        if field.currentEditor() == nil, field.stringValue != text {
            field.stringValue = text
        }
        applyCompletion(to: field)
        if context.coordinator.handledFocusRequest != focusRequest {
            context.coordinator.handledFocusRequest = focusRequest
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
    }

    /// Adds the rest of the site's name as selected text, so the next keystroke replaces it.
    private func applyCompletion(to field: NSTextField) {
        guard let inlineCompletion, let editor = field.currentEditor() as? NSTextView,
              editor.string == inlineCompletion.typed, !editor.hasMarkedText(),
              inlineCompletion.text != inlineCompletion.typed else { return }
        let typedLength = inlineCompletion.typed.utf16.count
        guard editor.selectedRange() == NSRange(location: typedLength, length: 0) else { return }
        editor.string = inlineCompletion.text
        editor.setSelectedRange(NSRange(location: typedLength, length: inlineCompletion.text.utf16.count - typedLength))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AddressField
        var handledFocusRequest: Int
        private var lastTyped = ""

        init(parent: AddressField) {
            self.parent = parent
            handledFocusRequest = parent.focusRequest
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let text = field.stringValue
            let grew = text.count > lastTyped.count
            lastTyped = text
            parent.onEdit(text, grew)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            lastTyped = ""
            parent.onEndEditing()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)):
                parent.onMoveSelection(1)
                return true
            case #selector(NSResponder.moveUp(_:)):
                parent.onMoveSelection(-1)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit(textView.string)
                control.window?.makeFirstResponder(nil)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                textView.string = parent.text
                textView.selectAll(nil)
                parent.onEndEditing()
                return true
            default:
                return false
            }
        }
    }
}
