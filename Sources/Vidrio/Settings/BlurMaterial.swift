import AppKit

/// User-selectable blur presets. Each maps to an NSVisualEffectView material,
/// except `.none` which means "no blur" (the visual effect view is hidden).
enum BlurMaterial: String, Codable, CaseIterable {
    case hudWindow
    case popover
    case sidebar
    case fullScreenUI
    case underWindowBackground
    case menu
    case none

    /// nil when blur should be disabled.
    var material: NSVisualEffectView.Material? {
        switch self {
        case .hudWindow: return .hudWindow
        case .popover: return .popover
        case .sidebar: return .sidebar
        case .fullScreenUI: return .fullScreenUI
        case .underWindowBackground: return .underWindowBackground
        case .menu: return .menu
        case .none: return nil
        }
    }

    var displayName: String {
        switch self {
        case .hudWindow: return "HUD"
        case .popover: return "Popover"
        case .sidebar: return "Barra lateral"
        case .fullScreenUI: return "Pantalla completa"
        case .underWindowBackground: return "Bajo ventana"
        case .menu: return "Menú"
        case .none: return "Ninguno"
        }
    }
}
