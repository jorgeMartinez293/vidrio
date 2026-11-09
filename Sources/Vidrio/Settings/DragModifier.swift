import AppKit

/// A modifier key that, held while dragging, picks what the drag does:
/// one rearranges panes (and merges windows), another swaps panes.
enum DragModifier: String, Codable, CaseIterable {
    case command
    case option
    case control
    case shift

    var flags: NSEvent.ModifierFlags {
        switch self {
        case .command: return .command
        case .option: return .option
        case .control: return .control
        case .shift: return .shift
        }
    }

    var displayName: String {
        switch self {
        case .command: return "⌘ Comando"
        case .option: return "⌥ Opción"
        case .control: return "⌃ Control"
        case .shift: return "⇧ Mayúsculas"
        }
    }

    /// Whether `flags` (from an event or `NSEvent.modifierFlags`) has this
    /// key held.
    func isHeld(in flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection(.deviceIndependentFlagsMask).contains(self.flags)
    }
}
