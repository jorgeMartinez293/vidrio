import Foundation

/// A desktop notification requested by a program through a terminal escape sequence.
struct TerminalMessage: Equatable {
    var title: String?
    var body: String
}

enum TerminalNotificationParser {
    /// OSC 9: the whole payload is the message. ConEmu reuses the code for numbered
    /// subcommands such as `9;4;1;50` (progress), which are not notifications.
    static func parseOSC9(_ payload: String) -> TerminalMessage? {
        let text = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let separator = text.firstIndex(of: ";"),
           !text[..<separator].isEmpty,
           text[..<separator].allSatisfy(\.isNumber) {
            return nil
        }
        return TerminalMessage(title: nil, body: text)
    }

    /// OSC 777: `notify;title;body`. The body may itself contain semicolons.
    static func parseOSC777(_ payload: String) -> TerminalMessage? {
        let parts = payload.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0] == "notify" else { return nil }
        let title = String(parts[1])
        let body = parts.count > 2 ? String(parts[2]) : ""
        if body.isEmpty {
            return title.isEmpty ? nil : TerminalMessage(title: nil, body: title)
        }
        return TerminalMessage(title: title.isEmpty ? nil : title, body: body)
    }
}

/// Assembles OSC 99 (kitty) notifications, which can arrive in several chunks:
/// `i=id:d=0:p=title;text` followed by `i=id:p=body;text`. `d=0` means more is coming.
struct KittyNotificationAssembler {
    private var pending: [String: TerminalMessage] = [:]

    mutating func feed(_ payload: String) -> TerminalMessage? {
        guard let separator = payload.firstIndex(of: ";") else { return nil }
        var fields: [String: String] = [:]
        for field in payload[..<separator].split(separator: ":") {
            let pair = field.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { fields[String(pair[0])] = String(pair[1]) }
        }
        var text = String(payload[payload.index(after: separator)...])
        if fields["e"] == "1" {
            guard let data = Data(base64Encoded: text),
                  let decoded = String(data: data, encoding: .utf8) else { return nil }
            text = decoded
        }

        let id = fields["i"] ?? ""
        var message = pending[id] ?? TerminalMessage(title: nil, body: "")
        switch fields["p"] ?? "title" {
        case "title": message.title = (message.title ?? "") + text
        case "body": message.body += text
        default: break
        }

        if fields["d"] == "0" {
            pending[id] = message
            return nil
        }
        pending[id] = nil
        if message.body.isEmpty, let title = message.title {
            message = TerminalMessage(title: nil, body: title)
        }
        return message.body.isEmpty ? nil : message
    }
}
