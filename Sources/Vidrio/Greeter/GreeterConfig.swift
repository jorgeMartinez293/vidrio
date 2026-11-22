import Foundation

enum DisplayMode: String, Codable, CaseIterable {
    case gif = "gif"
    case image = "image"
    case auto = "auto"

    var label: String {
        switch self {
        case .gif: return "GIF"
        case .image: return "Image"
        case .auto: return "Auto (battery)"
        }
    }
    var icon: String {
        switch self {
        case .gif: return "play.circle"
        case .image: return "photo"
        case .auto: return "bolt.badge.automatic"
        }
    }
}

/// File format unchanged from sereno's `ConfigManager`/`SerenoConfig` so an
/// existing `~/.config/sereno/config.json` keeps working without migration.
struct GreeterConfig: Codable {
    var selectedSprite: String?
    var displayMode: DisplayMode
    var enabledFields: [InfoField]
    /// `#RRGGBB` override for the info-line bullets and prompt color, or nil to keep
    /// the default: each sprite's own dominant color (`ColorExtractor.dominantColor`).
    var bulletColorHex: String?

    enum CodingKeys: String, CodingKey {
        case selectedSprite = "selected_sprite"
        case legacySelectedSprite = "selected_pokemon"
        case displayMode = "display_mode"
        case enabledFields = "enabled_fields"
        case bulletColorHex = "bullet_color"
    }

    init(selectedSprite: String? = nil, displayMode: DisplayMode = .auto, enabledFields: [InfoField] = InfoField.defaults, bulletColorHex: String? = nil) {
        self.selectedSprite = selectedSprite
        self.displayMode = displayMode
        self.enabledFields = enabledFields
        self.bulletColorHex = bulletColorHex
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.selectedSprite = try c.decodeIfPresent(String.self, forKey: .selectedSprite)
            ?? c.decodeIfPresent(String.self, forKey: .legacySelectedSprite)
        self.displayMode = try c.decodeIfPresent(DisplayMode.self, forKey: .displayMode) ?? .auto
        // Decode as raw strings rather than [InfoField] directly: an unrecognized
        // field name (e.g. saved by a newer vidrio) must not fail the whole decode.
        if let rawFields = try c.decodeIfPresent([String].self, forKey: .enabledFields) {
            self.enabledFields = rawFields.compactMap(InfoField.init(rawValue:))
        } else {
            self.enabledFields = InfoField.defaults
        }
        self.bulletColorHex = try c.decodeIfPresent(String.self, forKey: .bulletColorHex)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(selectedSprite, forKey: .selectedSprite)
        try c.encode(displayMode, forKey: .displayMode)
        try c.encode(enabledFields, forKey: .enabledFields)
        try c.encodeIfPresent(bulletColorHex, forKey: .bulletColorHex)
    }
}

enum GreeterConfigStore {
    static let configURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/sereno/config.json")

    /// Config left behind by an old pokefetch install; read-only fallback
    /// until it gets migrated by a save from the Greeter panel.
    static let legacyConfigURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/fastfetch/pokefetch_config.json")

    static func load() -> GreeterConfig {
        for url in [configURL, legacyConfigURL] {
            if let data = try? Data(contentsOf: url),
               let cfg = try? JSONDecoder().decode(GreeterConfig.self, from: data) {
                return cfg
            }
        }
        return GreeterConfig()
    }

    static func save(_ config: GreeterConfig) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        let data = try enc.encode(config)
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: configURL, options: .atomic)
    }
}
