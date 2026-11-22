import Cocoa

/// Small floating search field for a pane's output. Return finds the next match, ⇧Return
/// the previous one, Escape closes it.
final class FindBarView: NSVisualEffectView, NSSearchFieldDelegate {
    var onSearch: ((String, _ backwards: Bool) -> Void)?
    var onClose: (() -> Void)?

    private let field = NSSearchField()
    private let status = NSTextField(labelWithString: "")

    var query: String { field.stringValue }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true

        field.placeholderString = "Find"
        field.delegate = self
        field.sendsSearchStringImmediately = false
        field.sendsWholeSearchString = true
        field.focusRingType = .none
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.setContentHuggingPriority(.required, for: .horizontal)

        let previous = Self.button("chevron.up", "Previous match", self, #selector(findPrevious))
        let next = Self.button("chevron.down", "Next match", self, #selector(findNext))
        let close = Self.button("xmark", "Close", self, #selector(closeBar))

        let stack = NSStackView(views: [field, status, previous, next, close])
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func button(_ symbol: String, _ label: String, _ target: AnyObject, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage()
        let button = NSButton(image: image, target: target, action: action)
        button.isBordered = false
        button.toolTip = label
        return button
    }

    func focus() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func showResult(found: Bool) {
        status.stringValue = found || query.isEmpty ? "" : "No results"
    }

    @objc func findNext() { onSearch?(query, false) }
    @objc func findPrevious() { onSearch?(query, true) }
    @objc private func closeBar() { onClose?() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onSearch?(query, NSEvent.modifierFlags.contains(.shift))
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }
}
