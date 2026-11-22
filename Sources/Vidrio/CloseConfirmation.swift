import Cocoa

/// Asks before closing something that would stop a running program. Cancel is the default
/// button, so a stray Return after `⌘W` never kills anything.
@MainActor
enum CloseConfirmation {
    enum Scope {
        case pane, window, app

        fileprivate var title: String {
            switch self {
            case .pane: return "Close this pane?"
            case .window: return "Close this window?"
            case .app: return "Quit vidrio?"
            }
        }

        fileprivate var confirmLabel: String { self == .app ? "Quit" : "Close" }
    }

    /// Names each distinct program, up to three, then counts the rest.
    nonisolated static func informativeText(for processNames: [String]) -> String {
        var seen = Set<String>()
        let names = processNames.filter { seen.insert($0).inserted }.map { "“\($0)”" }
        let shown = names.prefix(3)
        let list: String
        if names.count > shown.count {
            list = shown.joined(separator: ", ") + " and \(names.count - shown.count) more"
        } else if shown.count > 1 {
            list = shown.dropLast().joined(separator: ", ") + " and " + shown.last!
        } else {
            list = shown.first ?? "A program"
        }
        return "\(list) \(names.count > 1 ? "are" : "is") still running and will be stopped."
    }

    private static func makeAlert(_ scope: Scope, processNames: [String]) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = scope.title
        alert.informativeText = informativeText(for: processNames)
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: scope.confirmLabel).hasDestructiveAction = true
        return alert
    }

    /// Shows the question as a sheet on `window`. `completion` gets true if the user confirmed;
    /// a sheet ended from code (its program exited meanwhile) reports false.
    static func present(
        _ scope: Scope, processNames: [String], on window: NSWindow,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        makeAlert(scope, processNames: processNames).beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                completion(response == .alertSecondButtonReturn)
            }
        }
    }

    /// Asks in a standalone dialog, for when no single window owns the question.
    static func confirm(_ scope: Scope, processNames: [String]) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        return makeAlert(scope, processNames: processNames).runModal() == .alertSecondButtonReturn
    }
}
