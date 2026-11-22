import Cocoa
import Carbon.HIToolbox

/// One key press with modifiers, written as text like `cmd+shift+p`.
struct KeyCombo: Hashable {
    var key: String
    var command = false
    var option = false
    var control = false
    var shift = false

    private static let namedKeys: Set<String> = [
        "left", "right", "up", "down", "return", "tab", "space", "escape", "delete", "plus",
    ]

    init?(_ text: String) {
        let tokens = text.lowercased().trimmingCharacters(in: .whitespaces)
            .split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let last = tokens.last, Self.isValidKey(last) else { return nil }
        key = last
        for token in tokens.dropLast() {
            switch token {
            case "cmd", "command": command = true
            case "opt", "option", "alt": option = true
            case "ctrl", "control": control = true
            case "shift": shift = true
            default: return nil
            }
        }
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags
        command = flags.contains(.command)
        option = flags.contains(.option)
        control = flags.contains(.control)
        shift = flags.contains(.shift)
        switch Int(event.keyCode) {
        case kVK_LeftArrow: key = "left"
        case kVK_RightArrow: key = "right"
        case kVK_UpArrow: key = "up"
        case kVK_DownArrow: key = "down"
        case kVK_Return: key = "return"
        case kVK_Tab: key = "tab"
        case kVK_Space: key = "space"
        case kVK_Escape: key = "escape"
        case kVK_Delete: key = "delete"
        default:
            guard let characters = event.charactersIgnoringModifiers?.lowercased(),
                  characters.count == 1 else { return nil }
            key = characters == "+" ? "plus" : characters
        }
    }

    private static func isValidKey(_ key: String) -> Bool {
        key.count == 1 || namedKeys.contains(key)
    }

    /// Normalized text form.
    var text: String {
        var parts: [String] = []
        if control { parts.append("ctrl") }
        if option { parts.append("option") }
        if shift { parts.append("shift") }
        if command { parts.append("cmd") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    /// As shown in menus, like `⌘⇧P`.
    var symbol: String {
        let modifiers = (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "")
        let names = [
            "left": "←", "right": "→", "up": "↑", "down": "↓", "return": "↩", "tab": "⇥",
            "space": "Space", "escape": "⎋", "delete": "⌫", "plus": "+",
        ]
        return modifiers + (names[key] ?? key.uppercased())
    }

    var keyEquivalent: String {
        switch key {
        case "left": return String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case "right": return String(UnicodeScalar(NSRightArrowFunctionKey)!)
        case "up": return String(UnicodeScalar(NSUpArrowFunctionKey)!)
        case "down": return String(UnicodeScalar(NSDownArrowFunctionKey)!)
        case "return": return "\r"
        case "tab": return "\t"
        case "space": return " "
        case "escape": return "\u{1B}"
        case "delete": return "\u{8}"
        case "plus": return "+"
        default: return key
        }
    }

    var modifierMask: NSEvent.ModifierFlags {
        var mask: NSEvent.ModifierFlags = []
        if command { mask.insert(.command) }
        if option { mask.insert(.option) }
        if control { mask.insert(.control) }
        if shift { mask.insert(.shift) }
        return mask
    }

    // MARK: - Global hotkey

    var carbonModifiers: UInt32 {
        var mask: UInt32 = 0
        if command { mask |= UInt32(cmdKey) }
        if option { mask |= UInt32(optionKey) }
        if control { mask |= UInt32(controlKey) }
        if shift { mask |= UInt32(shiftKey) }
        return mask
    }

    /// Physical key for the global hotkey API, which works on key positions (ANSI layout).
    var carbonKeyCode: UInt32? {
        let table: [String: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
            "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
            "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
            "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
            "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
            "z": kVK_ANSI_Z, "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
            "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8,
            "9": kVK_ANSI_9, "`": kVK_ANSI_Grave, "space": kVK_Space, "return": kVK_Return,
            "tab": kVK_Tab, "escape": kVK_Escape, "left": kVK_LeftArrow, "right": kVK_RightArrow,
            "up": kVK_UpArrow, "down": kVK_DownArrow,
        ]
        return table[key].map(UInt32.init)
    }
}

/// A shortcut: one combo, or a two-step chord like `ctrl+b c`.
struct KeyBinding: Equatable {
    let steps: [KeyCombo]

    init?(_ text: String) {
        let parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard (1...2).contains(parts.count) else { return nil }
        let combos = parts.compactMap(KeyCombo.init)
        guard combos.count == parts.count else { return nil }
        steps = combos
    }

    var isChord: Bool { steps.count > 1 }
    var text: String { steps.map(\.text).joined(separator: " ") }
    var symbol: String { steps.map(\.symbol).joined(separator: " ") }
}

/// Tracks a chord in progress across key presses.
struct ChordMatcher<ID: Hashable> {
    enum Outcome: Equatable {
        /// Not part of any chord: let the key through.
        case ignored
        /// First step matched: swallow the key and wait for the second.
        case pending
        case fired(ID)
        /// A chord was started but the second key didn't match: swallow it.
        case cancelled
    }

    private let chords: [(id: ID, first: KeyCombo, second: KeyCombo)]
    private var prefix: KeyCombo?

    init(bindings: [(ID, KeyBinding)]) {
        chords = bindings.compactMap { id, binding in
            binding.isChord ? (id, binding.steps[0], binding.steps[1]) : nil
        }
    }

    var isEmpty: Bool { chords.isEmpty }

    mutating func handle(_ combo: KeyCombo) -> Outcome {
        if let current = prefix {
            prefix = nil
            let match = chords.first { $0.first == current && $0.second == combo }
            return match.map { .fired($0.id) } ?? .cancelled
        }
        guard chords.contains(where: { $0.first == combo }) else { return .ignored }
        prefix = combo
        return .pending
    }
}
