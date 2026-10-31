import AppKit
import SwiftUI

/// AppKit-backed so Enter and Escape can be intercepted. Omnibox completion builds on this in Phase 2.
struct AddressField: NSViewRepresentable {
    let text: String
    let placeholder: String
    let focusRequest: Int
    let onSubmit: (String) -> Void
    let onEdit: (String) -> Void
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
        if context.coordinator.handledFocusRequest != focusRequest {
            context.coordinator.handledFocusRequest = focusRequest
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AddressField
        var handledFocusRequest: Int

        init(parent: AddressField) {
            self.parent = parent
            handledFocusRequest = parent.focusRequest
        }

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { parent.onEdit(field.stringValue) }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
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
