import Cocoa
import Carbon.HIToolbox

/// A system-wide shortcut. Uses Carbon's hotkey API, the one route that needs no
/// Accessibility permission.
@MainActor
final class GlobalHotKey {
    private static var active: GlobalHotKey?
    private static var handlerInstalled = false

    private var reference: EventHotKeyRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    /// Replaces any current registration. Returns false if the key can't be registered,
    /// for example because another app already owns it.
    @discardableResult
    func register(_ combo: KeyCombo) -> Bool {
        unregister()
        guard let keyCode = combo.carbonKeyCode else { return false }
        Self.installHandlerIfNeeded()
        let id = EventHotKeyID(signature: OSType(0x7664_7269), id: 1) // "vdri"
        let status = RegisterEventHotKey(
            keyCode, combo.carbonModifiers, id, GetApplicationEventTarget(), 0, &reference
        )
        guard status == noErr else {
            reference = nil
            return false
        }
        Self.active = self
        return true
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        if Self.active === self { Self.active = nil }
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { GlobalHotKey.active?.action() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
