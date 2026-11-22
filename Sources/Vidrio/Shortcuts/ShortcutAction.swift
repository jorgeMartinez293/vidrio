import Cocoa

/// Every command with a configurable shortcut. Raw values are the keys of the `shortcuts`
/// setting, so they must stay stable.
enum ShortcutAction: String, CaseIterable, Identifiable {
    case newWindow, newPane, closePane
    case commandPalette, settings
    case find, findNext, findPrevious
    case clearTerminal, previousPrompt, nextPrompt
    case increaseFont, decreaseFont, resetFont
    case toggleFullScreen, minimizeWindow
    case zoomPane, jumpToUnread
    case focusUp, focusDown, focusLeft, focusRight
    case focusPane1, focusPane2, focusPane3, focusPane4, focusPane5
    case focusPane6, focusPane7, focusPane8, focusPane9
    case workspaceSwitcher, newWorkspace, renameWorkspace, nextWorkspace, previousWorkspace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newWindow: return "New Window"
        case .newPane: return "New Pane"
        case .closePane: return "Close Pane"
        case .commandPalette: return "Command Palette…"
        case .settings: return "Settings…"
        case .find: return "Find…"
        case .findNext: return "Find Next"
        case .findPrevious: return "Find Previous"
        case .clearTerminal: return "Clear Terminal"
        case .previousPrompt: return "Previous Prompt"
        case .nextPrompt: return "Next Prompt"
        case .increaseFont: return "Increase Font Size"
        case .decreaseFont: return "Decrease Font Size"
        case .resetFont: return "Reset Font Size"
        case .toggleFullScreen: return "Toggle Full Screen"
        case .minimizeWindow: return "Minimize"
        case .zoomPane: return "Zoom Pane"
        case .jumpToUnread: return "Jump to Latest Unread"
        case .focusUp: return "Focus Pane Above"
        case .focusDown: return "Focus Pane Below"
        case .focusLeft: return "Focus Pane Left"
        case .focusRight: return "Focus Pane Right"
        case .workspaceSwitcher: return "Switch Workspace…"
        case .newWorkspace: return "New Workspace…"
        case .renameWorkspace: return "Rename Workspace…"
        case .nextWorkspace: return "Next Workspace"
        case .previousWorkspace: return "Previous Workspace"
        default: return "Focus Pane \(paneNumber ?? 0)"
        }
    }

    /// 1...9 for the direct pane shortcuts.
    var paneNumber: Int? {
        rawValue.hasPrefix("focusPane") ? Int(rawValue.dropFirst("focusPane".count)) : nil
    }

    var defaultBinding: String {
        switch self {
        case .newWindow: return "cmd+n"
        case .newPane: return "cmd+shift+n"
        case .closePane: return "cmd+w"
        case .commandPalette: return "cmd+shift+p"
        case .settings: return "cmd+,"
        case .find: return "cmd+f"
        case .findNext: return "cmd+g"
        case .findPrevious: return "cmd+shift+g"
        case .clearTerminal: return "cmd+k"
        case .previousPrompt: return "option+cmd+up"
        case .nextPrompt: return "option+cmd+down"
        case .increaseFont: return "cmd+plus"
        case .decreaseFont: return "cmd+-"
        case .resetFont: return "cmd+0"
        case .toggleFullScreen: return "ctrl+cmd+f"
        case .minimizeWindow: return "cmd+m"
        case .zoomPane: return "cmd+shift+return"
        case .jumpToUnread: return "cmd+shift+u"
        case .focusUp: return "cmd+up"
        case .focusDown: return "cmd+down"
        case .focusLeft: return "cmd+left"
        case .focusRight: return "cmd+right"
        case .workspaceSwitcher: return "cmd+shift+o"
        case .newWorkspace: return "option+cmd+n"
        case .renameWorkspace: return ""
        case .nextWorkspace: return "ctrl+cmd+right"
        case .previousWorkspace: return "ctrl+cmd+left"
        default: return "ctrl+\(paneNumber ?? 1)"
        }
    }

    /// Dispatched through the responder chain, so the focused pane, its grid or the app
    /// delegate handles it, and menu items disable themselves when nothing can.
    var selector: Selector {
        switch self {
        case .newWindow: return #selector(AppDelegate.newWindow(_:))
        case .newPane: return #selector(GridViewController.addGridPane(_:))
        case .closePane: return #selector(AppDelegate.closeFocusedTerminal(_:))
        case .commandPalette: return #selector(AppDelegate.showCommandPalette(_:))
        case .settings: return #selector(AppDelegate.openSettings(_:))
        case .find: return #selector(TerminalViewController.showFindBar(_:))
        case .findNext: return #selector(TerminalViewController.findNextMatch(_:))
        case .findPrevious: return #selector(TerminalViewController.findPreviousMatch(_:))
        case .clearTerminal: return #selector(TerminalViewController.clearTerminal(_:))
        case .previousPrompt: return #selector(TerminalViewController.jumpToPreviousPrompt(_:))
        case .nextPrompt: return #selector(TerminalViewController.jumpToNextPrompt(_:))
        case .increaseFont: return #selector(TerminalViewController.increaseFontSize(_:))
        case .decreaseFont: return #selector(TerminalViewController.decreaseFontSize(_:))
        case .resetFont: return #selector(TerminalViewController.resetFontSize(_:))
        case .toggleFullScreen: return #selector(NSWindow.toggleFullScreen(_:))
        case .minimizeWindow: return #selector(NSWindow.performMiniaturize(_:))
        case .zoomPane: return #selector(GridViewController.toggleZoomPane(_:))
        case .jumpToUnread: return #selector(AppDelegate.jumpToLatestUnread(_:))
        case .focusUp: return #selector(GridViewController.moveGridFocusUp(_:))
        case .focusDown: return #selector(GridViewController.moveGridFocusDown(_:))
        case .focusLeft: return #selector(GridViewController.moveGridFocusLeft(_:))
        case .focusRight: return #selector(GridViewController.moveGridFocusRight(_:))
        case .workspaceSwitcher: return #selector(AppDelegate.showWorkspaceSwitcher(_:))
        case .newWorkspace: return #selector(AppDelegate.newWorkspace(_:))
        case .renameWorkspace: return #selector(AppDelegate.renameWorkspace(_:))
        case .nextWorkspace: return #selector(AppDelegate.selectNextWorkspace(_:))
        case .previousWorkspace: return #selector(AppDelegate.selectPreviousWorkspace(_:))
        default: return #selector(GridViewController.focusPaneByNumber(_:))
        }
    }

    /// The binding in effect: the user's override, or the default. An empty override
    /// unbinds the action; an invalid one is ignored.
    func binding(overrides: [String: String]) -> KeyBinding? {
        if let override = overrides[rawValue] {
            let trimmed = override.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return nil }
            if let parsed = KeyBinding(trimmed) { return parsed }
        }
        return KeyBinding(defaultBinding)
    }
}
