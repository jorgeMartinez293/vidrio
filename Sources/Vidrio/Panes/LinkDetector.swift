import Cocoa

/// Something clickable found in terminal text.
enum DetectedLink: Equatable {
    case url(String)
    case file(path: String, line: Int?, column: Int?)
}

/// A link and the characters of the text it spans.
struct LinkMatch: Equatable {
    let link: DetectedLink
    let range: Range<Int>
}

enum LinkDetector {
    private static let leadingWrappers = CharacterSet(charactersIn: "(\"'[<{`")
    private static let trailingWrappers = CharacterSet(charactersIn: ")\"']>}`,.;!?")

    /// The link under `offset` (a character index into `text`), if any.
    static func link(in text: String, atOffset offset: Int) -> DetectedLink? {
        match(in: text, atOffset: offset)?.link
    }

    /// The target of an OSC 8 hyperlink, stored by the terminal as `params;url`.
    static func hyperlinkURL(payload: String) -> String? {
        guard let separator = payload.firstIndex(of: ";") else { return nil }
        let url = payload[payload.index(after: separator)...]
        return url.isEmpty ? nil : String(url)
    }

    static func match(in text: String, atOffset offset: Int) -> LinkMatch? {
        let characters = Array(text)
        guard characters.indices.contains(offset), !characters[offset].isWhitespace else { return nil }
        var start = offset
        while start > 0, !characters[start - 1].isWhitespace { start -= 1 }
        var end = offset
        while end + 1 < characters.count, !characters[end + 1].isWhitespace { end += 1 }

        while start < end, isIn(leadingWrappers, characters[start]) { start += 1 }
        while end > start, isIn(trailingWrappers, characters[end]),
              !closesBalancedParenthesis(characters, start: start, end: end) {
            end -= 1
        }
        guard offset >= start, offset <= end else { return nil }
        let token = String(characters[start...end])

        if let scheme = token.range(of: #"https?://"#, options: .regularExpression) {
            let urlOffset = token.distance(from: token.startIndex, to: scheme.lowerBound)
            guard offset - start >= urlOffset else { return nil }
            return LinkMatch(link: .url(String(token[scheme.lowerBound...])), range: (start + urlOffset)..<(end + 1))
        }
        return parseFile(token).map { LinkMatch(link: $0, range: start..<(end + 1)) }
    }

    private static func isIn(_ set: CharacterSet, _ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy(set.contains)
    }

    /// Keeps the `)` of URLs like `wiki/Foo_(bar)`.
    private static func closesBalancedParenthesis(_ characters: [Character], start: Int, end: Int) -> Bool {
        guard characters[end] == ")" else { return false }
        let token = characters[start...end]
        return token.filter { $0 == "(" }.count >= token.filter { $0 == ")" }.count
    }

    private static func parseFile(_ token: String) -> DetectedLink? {
        guard let match = token.firstMatch(of: /^(.+?)(?::(\d+))?(?::(\d+))?:?$/) else { return nil }
        let path = String(match.1)
        let name = path.split(separator: "/").last.map(String.init) ?? path
        let hasExtension = name.dropFirst().contains(".") && !name.hasSuffix(".")
        guard path.contains("/") || hasExtension,
              path.range(of: #"^[\w@~./+\-]+$"#, options: .regularExpression) != nil else { return nil }
        return .file(path: path, line: match.2.flatMap { Int($0) }, column: match.3.flatMap { Int($0) })
    }
}

/// Decides what a click in the terminal may open. Terminal text is untrusted: a program can
/// print a link whose visible text differs from its target.
enum LinkPolicy {
    private static let allowedSchemes: Set<String> = ["http", "https", "mailto"]
    /// Opening these with the default app would run them.
    private static let runnableExtensions: Set<String> = [
        "app", "command", "tool", "terminal", "pkg", "mpkg", "workflow", "scpt", "scptd",
        "action", "jar", "sh", "bash", "zsh", "dmg", "prefpane", "webloc", "inetloc",
    ]

    static func allowsURL(_ link: String) -> Bool {
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "file" { return allowsFile(atPath: url.path) }
        return allowedSchemes.contains(scheme)
    }

    static func allowsFile(atPath path: String, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { return false }
        if !isDirectory.boolValue, fileManager.isExecutableFile(atPath: path) { return false }
        return !runnableExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    /// Whether clicking `link` would actually open something.
    static func canOpen(_ link: DetectedLink, workingDirectory: String?) -> Bool {
        switch link {
        case .url(let text):
            return allowsURL(text)
        case .file(let path, _, _):
            guard let resolved = resolve(path, relativeTo: workingDirectory) else { return false }
            return allowsFile(atPath: resolved)
        }
    }

    /// Absolute path of an existing file, resolving `~` and paths relative to `directory`.
    static func resolve(_ path: String, relativeTo directory: String?, fileManager: FileManager = .default) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        let absolute: String
        if expanded.hasPrefix("/") {
            absolute = expanded
        } else if let directory {
            absolute = (directory as NSString).appendingPathComponent(expanded)
        } else {
            return nil
        }
        let standardized = (absolute as NSString).standardizingPath
        return fileManager.fileExists(atPath: standardized) ? standardized : nil
    }

    /// Fills an editor command template. The path is shell-quoted because it comes from
    /// terminal output and the command runs through a shell.
    static func editorCommand(template: String, path: String, line: Int?, column: Int?) -> String {
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return template
            .replacingOccurrences(of: "{file}", with: quoted)
            .replacingOccurrences(of: "{line}", with: String(line ?? 1))
            .replacingOccurrences(of: "{column}", with: String(column ?? 1))
    }
}

@MainActor
enum LinkOpener {
    static func open(_ link: DetectedLink, workingDirectory: String?) {
        switch link {
        case .url(let text):
            guard LinkPolicy.allowsURL(text), let url = URL(string: text) else { return }
            NSWorkspace.shared.open(url)
        case .file(let path, let line, let column):
            guard let resolved = LinkPolicy.resolve(path, relativeTo: workingDirectory),
                  LinkPolicy.allowsFile(atPath: resolved) else { return }
            let template = SettingsStore.shared.current.editorCommand
                .trimmingCharacters(in: .whitespaces)
            guard !template.isEmpty else {
                NSWorkspace.shared.open(URL(fileURLWithPath: resolved))
                return
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [
                "-lc", LinkPolicy.editorCommand(template: template, path: resolved, line: line, column: column),
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
        }
    }
}
