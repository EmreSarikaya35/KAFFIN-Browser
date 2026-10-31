import AppKit
import SwiftUI

/// AppKit-backed so Enter and Escape can be intercepted. Omnibox completion builds on this in Phase 2.
struct AddressField: NSViewRepresentable {
    let text: String
    let placeholder: String
    let focusRequest: Int
    let onSubmit: (String) -> Void

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

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit(textView.string)
                control.window?.makeFirstResponder(nil)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                textView.string = parent.text
                textView.selectAll(nil)
                return true
            default:
                return false
            }
        }
    }
}
