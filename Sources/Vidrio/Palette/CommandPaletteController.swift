import Cocoa

struct PaletteItem {
    let title: String
    var subtitle: String = ""
    var shortcut: String = ""
    let action: @MainActor () -> Void
}

/// Floating search list used for the command palette and the workspace switcher. It appears
/// on demand and leaves no chrome behind. ↑/↓ move, Return runs, Escape dismisses.
@MainActor
final class CommandPaletteController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    private static let width: CGFloat = 560
    private static let maxVisibleRows = 9
    private static let rowHeight: CGFloat = 42
    private static let fieldHeight: CGFloat = 48

    private let panel: PalettePanel
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var items: [PaletteItem] = []
    private var visible: [PaletteItem] = []
    private var defaultRow = 0

    override init() {
        panel = PalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.fieldHeight),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered, defer: true
        )
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true
        panel.contentView = background

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 18)
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("item"))
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(runClickedRow)

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(field)
        background.addSubview(scroll)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: background.topAnchor, constant: 13),
            field.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: background.topAnchor, constant: Self.fieldHeight),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
    }

    var isVisible: Bool { panel.isVisible }

    /// `row` is the item selected while the search field is empty.
    func show(items: [PaletteItem], placeholder: String, over window: NSWindow?, selecting row: Int = 0) {
        self.items = items
        defaultRow = row
        field.stringValue = ""
        field.placeholderString = placeholder
        filter()
        position(over: window)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        table.scrollRowToVisible(table.selectedRow)
    }

    /// Swaps the items while open (for details that load in the background), keeping the
    /// query and the selected item.
    func update(items: [PaletteItem]) {
        guard panel.isVisible else { return }
        let selected = visible.indices.contains(table.selectedRow) ? visible[table.selectedRow].title : nil
        self.items = items
        filter(keepingSelectionOn: selected)
    }

    func dismiss() {
        panel.orderOut(nil)
    }

    private func position(over window: NSWindow?) {
        let area = window?.frame ?? NSScreen.main?.visibleFrame ?? .zero
        let height = panelHeight
        panel.setFrame(NSRect(
            x: area.midX - Self.width / 2,
            y: area.maxY - area.height * 0.18 - height,
            width: Self.width, height: height
        ), display: false)
    }

    private var panelHeight: CGFloat {
        Self.fieldHeight + CGFloat(min(visible.count, Self.maxVisibleRows)) * Self.rowHeight + (visible.isEmpty ? 0 : 6)
    }

    private func filter(keepingSelectionOn selectedTitle: String? = nil) {
        let query = field.stringValue
        let isSearching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        if !isSearching {
            visible = items
        } else {
            visible = items
                .compactMap { item -> (PaletteItem, Int)? in
                    let titleScore = FuzzyMatcher.score(query: query, in: item.title)
                    let subtitleScore = FuzzyMatcher.score(query: query, in: item.subtitle).map { $0 / 2 }
                    guard let best = [titleScore, subtitleScore].compactMap({ $0 }).max() else { return nil }
                    return (item, best)
                }
                .sorted { $0.1 > $1.1 }
                .map(\.0)
        }
        table.reloadData()
        if !visible.isEmpty {
            let row = selectedTitle.flatMap { title in visible.firstIndex { $0.title == title } }
                ?? (isSearching ? 0 : min(defaultRow, visible.count - 1))
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        if panel.isVisible {
            var frame = panel.frame
            let height = panelHeight
            frame.origin.y += frame.height - height
            frame.size.height = height
            panel.setFrame(frame, display: true)
        }
    }

    private func run(row: Int) {
        guard visible.indices.contains(row) else { return }
        let action = visible[row].action
        dismiss()
        // After the panel has given key status back, so responder-chain actions reach
        // the terminal window.
        DispatchQueue.main.async {
            MainActor.assumeIsolated { action() }
        }
    }

    @objc private func runClickedRow() {
        run(row: table.clickedRow)
    }

    private func moveSelection(by delta: Int) {
        guard !visible.isEmpty else { return }
        let count = visible.count
        let row = ((table.selectedRow + delta) % count + count) % count
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    // MARK: - Delegates

    func controlTextDidChange(_ notification: Notification) {
        filter()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): moveSelection(by: 1)
        case #selector(NSResponder.moveUp(_:)): moveSelection(by: -1)
        case #selector(NSResponder.insertNewline(_:)): run(row: table.selectedRow)
        case #selector(NSResponder.cancelOperation(_:)): dismiss()
        default: return false
        }
        return true
    }

    func windowDidResignKey(_ notification: Notification) {
        dismiss()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        visible.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = visible[row]
        return PaletteRowView(title: item.title, subtitle: item.subtitle, shortcut: item.shortcut)
    }
}

private final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class PaletteRowView: NSView {
    init(title: String, subtitle: String, shortcut: String) {
        super.init(frame: .zero)
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.isHidden = subtitle.isEmpty
        let shortcutLabel = NSTextField(labelWithString: shortcut)
        shortcutLabel.font = .systemFont(ofSize: 12)
        shortcutLabel.textColor = .secondaryLabelColor
        shortcutLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        shortcutLabel.setContentHuggingPriority(.required, for: .horizontal)

        let text = NSStackView(views: [titleLabel, subtitleLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [text, shortcutLabel])
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
