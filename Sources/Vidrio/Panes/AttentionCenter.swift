import Cocoa
import UserNotifications

/// Tracks which panes need the user: unread activity, agent states, the Dock badge and
/// desktop notifications.
@MainActor
final class AttentionCenter: NSObject {
    static let shared = AttentionCenter()

    private let panes = NSMapTable<NSString, TerminalViewController>.strongToWeakObjects()
    /// Unread pane ids, oldest first.
    private var unread: [String] = []
    private var didRequestAuthorization = false

    /// `UNUserNotificationCenter` crashes in a process with no app bundle (`swift run`).
    private var canPostNotifications: Bool { Bundle.main.bundleIdentifier != nil }

    func start() {
        guard canPostNotifications else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    func register(_ pane: TerminalViewController) {
        panes.setObject(pane, forKey: pane.paneID as NSString)
    }

    func unregister(_ pane: TerminalViewController) {
        panes.removeObject(forKey: pane.paneID as NSString)
        unread.removeAll { $0 == pane.paneID }
        updateDockBadge()
        try? FileManager.default.removeItem(
            at: AgentHooks.stateDirectory.appendingPathComponent(pane.paneID)
        )
    }

    func pane(withID id: String) -> TerminalViewController? {
        panes.object(forKey: id as NSString)
    }

    // MARK: - Unread

    /// A program asked for attention. Ignored when the user is already looking at the pane.
    func notify(_ pane: TerminalViewController, message: TerminalMessage) {
        guard !pane.isFrontmostPane else { return }
        markUnread(pane)
        post(message, paneID: pane.paneID)
    }

    /// A terminal bell: marks the pane without a desktop notification.
    func ring(_ pane: TerminalViewController) {
        guard !pane.isFrontmostPane else { return }
        markUnread(pane)
    }

    private func markUnread(_ pane: TerminalViewController) {
        unread.removeAll { $0 == pane.paneID }
        unread.append(pane.paneID)
        pane.hasUnreadActivity = true
        updateDockBadge()
    }

    func markRead(_ pane: TerminalViewController) {
        guard pane.hasUnreadActivity else { return }
        pane.hasUnreadActivity = false
        unread.removeAll { $0 == pane.paneID }
        updateDockBadge()
    }

    func jumpToLatestUnread() {
        while let id = unread.last {
            if let pane = pane(withID: id) {
                reveal(pane)
                return
            }
            unread.removeLast()
        }
        updateDockBadge()
    }

    private func reveal(_ pane: TerminalViewController) {
        (NSApp.delegate as? AppDelegate)?.reveal(pane)
    }

    private func updateDockBadge() {
        NSApp.dockTile.badgeLabel = unread.isEmpty ? nil : String(unread.count)
    }

    // MARK: - Agent state

    /// Applies every changed file in the agent state directory.
    func applyAgentStateFiles(at paths: [String]) {
        let directory = AgentHooks.stateDirectory.path
        for path in Set(paths) where (path as NSString).deletingLastPathComponent == directory {
            let id = (path as NSString).lastPathComponent
            guard let pane = pane(withID: id),
                  let text = try? String(contentsOfFile: path, encoding: .utf8),
                  let report = AgentStateReport.parse(text) else { continue }
            apply(report, to: pane)
        }
    }

    func apply(_ report: AgentStateReport, to pane: TerminalViewController) {
        let previous = pane.agentState
        pane.agentState = report.state
        guard report.state != previous else { return }
        switch report.state {
        case .waiting: notify(pane, message: TerminalMessage(title: pane.displayTitle, body: "Needs your input"))
        case .done: notify(pane, message: TerminalMessage(title: pane.displayTitle, body: "Finished"))
        case .error: notify(pane, message: TerminalMessage(title: pane.displayTitle, body: "Stopped with an error"))
        case .working, nil: break
        }
    }

    // MARK: - Desktop notifications

    private func post(_ message: TerminalMessage, paneID: String) {
        guard canPostNotifications else { return }
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = message.title ?? "vidrio"
        content.body = message.body
        content.sound = .default
        content.userInfo = ["pane": paneID]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        guard !didRequestAuthorization else {
            center.add(request)
            return
        }
        didRequestAuthorization = true
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if granted { center.add(request) }
        }
    }
}

extension AttentionCenter: UNUserNotificationCenterDelegate {
    /// Clicking a notification brings its pane forward.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let id = response.notification.request.content.userInfo["pane"] as? String
        Task { @MainActor in
            if let id, let pane = AttentionCenter.shared.pane(withID: id) {
                AttentionCenter.shared.reveal(pane)
            }
        }
        completionHandler()
    }

    /// Shown even with vidrio in front: the pane that asked is not the one being looked at.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
