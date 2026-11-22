import Foundation

/// What the coding agent running in a pane is doing.
enum AgentState: String, Codable, Equatable {
    case working, waiting, done, error
}

/// One state update, on the first line of what the agent hook script writes. `ended` clears
/// the state.
struct AgentStateReport: Equatable {
    let state: AgentState?

    static func parse(_ text: String) -> AgentStateReport? {
        guard let first = text.split(separator: "\n", omittingEmptySubsequences: false).first else { return nil }
        if first == "ended" { return AgentStateReport(state: nil) }
        return AgentState(rawValue: String(first)).map { AgentStateReport(state: $0) }
    }
}

/// Installs the Claude Code hooks that report each pane's agent state to vidrio. Hooks are
/// commands Claude Code runs on its own events. They write a small file per pane, which the
/// app's config watcher picks up.
enum AgentHooks {
    private static let home = FileManager.default.homeDirectoryForCurrentUser
    static let stateDirectory = home.appendingPathComponent(".config/vidrio/agent-state")
    static let scriptFile = home.appendingPathComponent(".config/vidrio/bin/vidrio-agent-state")
    static let claudeSettingsFile = home.appendingPathComponent(".claude/settings.json")

    private static let marker = "vidrio-agent-state"
    private static let events: [(event: String, state: String)] = [
        ("UserPromptSubmit", "working"),
        ("PreToolUse", "working"),
        ("PostToolUse", "working"),
        ("Notification", "waiting"),
        ("Stop", "done"),
        ("SessionEnd", "ended"),
    ]

    enum HookError: LocalizedError {
        case unreadableSettings

        var errorDescription: String? {
            "~/.claude/settings.json is not valid JSON, so it was left untouched."
        }
    }

    /// Does nothing outside a vidrio pane. Idle reminders are skipped so a finished turn
    /// doesn't turn into "waiting" a minute later.
    static let script = """
    #!/bin/sh
    # Reports Claude Code's state to the vidrio pane it runs in.
    [ -n "$VIDRIO_PANE_ID" ] || exit 0
    case "$VIDRIO_PANE_ID" in *[!A-Za-z0-9-]*) exit 0 ;; esac
    input=$(cat)
    if [ "$1" = waiting ]; then
      case "$input" in *idle_prompt*|*"waiting for your input"*) exit 0 ;; esac
    fi
    dir="$HOME/.config/vidrio/agent-state"
    mkdir -p "$dir"
    tmp="$dir/.$VIDRIO_PANE_ID.$$"
    printf '%s\\n' "$1" > "$tmp" && mv "$tmp" "$dir/$VIDRIO_PANE_ID"
    exit 0
    """

    private static func isOurs(_ entry: Any) -> Bool {
        guard let hooks = (entry as? [String: Any])?["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains { ($0["command"] as? String)?.contains(marker) == true }
    }

    static func isInstalled(in settings: [String: Any]) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { (hooks[$0.event] as? [Any])?.contains(where: isOurs) == true }
    }

    /// `settings` with vidrio's hooks added, keeping everything else as it was.
    static func merged(_ settings: [String: Any], scriptPath: String) -> [String: Any] {
        var result = removed(settings)
        var hooks = result["hooks"] as? [String: Any] ?? [:]
        for (event, state) in events {
            var entries = hooks[event] as? [Any] ?? []
            let command = "\"\(scriptPath)\" \(state)"
            entries.append(["hooks": [["type": "command", "command": command]]])
            hooks[event] = entries
        }
        result["hooks"] = hooks
        return result
    }

    /// `settings` without vidrio's hooks. Events left empty are dropped.
    static func removed(_ settings: [String: Any]) -> [String: Any] {
        var result = settings
        guard var hooks = result["hooks"] as? [String: Any] else { return result }
        for (event, _) in events {
            guard let entries = hooks[event] as? [Any] else { continue }
            let kept = entries.filter { !isOurs($0) }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        result["hooks"] = hooks.isEmpty ? nil : hooks
        return result
    }

    static func readSettings(at file: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: file.resolvingSymlinksInPath()), !data.isEmpty else {
            return [:]
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HookError.unreadableSettings
        }
        return object
    }

    static func install(settingsFile: URL = claudeSettingsFile, scriptFile: URL = scriptFile) throws {
        let settings = try readSettings(at: settingsFile)
        let fm = FileManager.default
        try fm.createDirectory(at: scriptFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try script.write(to: scriptFile, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptFile.path)
        try write(merged(settings, scriptPath: scriptFile.path), to: settingsFile)
    }

    static func uninstall(settingsFile: URL = claudeSettingsFile) throws {
        try write(removed(try readSettings(at: settingsFile)), to: settingsFile)
    }

    /// Writes through a symlink, keeps permissions, and leaves a backup of the previous file.
    private static func write(_ settings: [String: Any], to file: URL) throws {
        let fm = FileManager.default
        let target = file.resolvingSymlinksInPath()
        let data = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        var permissions: Any?
        if fm.fileExists(atPath: target.path) {
            permissions = try fm.attributesOfItem(atPath: target.path)[.posixPermissions]
            let backup = file.deletingLastPathComponent()
                .appendingPathComponent(file.lastPathComponent + ".vidrio-backup")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: target, to: backup)
        }
        try data.write(to: target, options: .atomic)
        if let permissions {
            try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
        }
    }
}
