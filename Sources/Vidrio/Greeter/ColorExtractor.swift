import SwiftUI
import AppKit

/// Dominant pastel color of an image, ignoring dark/transparent pixels.
/// Ported from sereno's get_color.py (Python + Pillow) — same dark threshold
/// (40) and pastel factor (0.4) — dropping the Python/Pillow dependency.
struct SpriteColor: Equatable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    var color: Color { Color(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255) }

    /// `#RRGGBB`, used to persist a user-chosen override in config.json.
    var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }

    init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red; self.green = green; self.blue = blue
    }

    init?(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.red = UInt8((v >> 16) & 0xFF)
        self.green = UInt8((v >> 8) & 0xFF)
        self.blue = UInt8(v & 0xFF)
    }

    /// `ESC[38;2;R;G;Bm` truecolor SGR sequence, used by GreetingRenderer to
    /// tint the info-line bullets — replaces fastfetch's `--color-keys <hex>`.
    var ansiForeground: [UInt8] {
        Array("\u{1B}[38;2;\(red);\(green);\(blue)m".utf8)
    }

    static let fallback = SpriteColor(red: 255, green: 255, blue: 255)
}

enum ColorExtractor {
    private static let cache = SpriteFileCache<SpriteColor>()

    /// Memoized per file: every new window tints its prompt from the same sprite.
    static func dominantColor(for url: URL) -> SpriteColor {
        cache.value(for: url) {
            guard let nsImage = NSImage(contentsOf: url),
                  let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else { return nil }
            return dominantColor(for: cgImage)
        } ?? .fallback
    }

    /// The color to tint the info-line bullets and prompt with: a user-chosen
    /// override if set, otherwise the sprite's own dominant color (the default).
    static func resolvedColor(for url: URL, overrideHex: String?) -> SpriteColor {
        if let overrideHex, let custom = SpriteColor(hex: overrideHex) { return custom }
        return dominantColor(for: url)
    }

    static func dominantColor(for cgImage: CGImage) -> SpriteColor {
        let w = cgImage.width, h = cgImage.height
        let bpp = 4
        var raw = [UInt8](repeating: 0, count: h * w * bpp)

        guard let ctx = CGContext(
            data: &raw, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * bpp,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return .fallback }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        let darkThreshold = 40
        var counts: [UInt32: Int] = [:]
        let step = 4

        for y in stride(from: 0, to: h, by: step) {
            for x in stride(from: 0, to: w, by: step) {
                let i = (y * w + x) * bpp
                let r = Int(raw[i]), g = Int(raw[i + 1]), b = Int(raw[i + 2]), a = Int(raw[i + 3])
                guard a >= 128 else { continue }
                guard r >= darkThreshold || g >= darkThreshold || b >= darkThreshold else { continue }
                let key = (UInt32(r >> 4) << 8) | (UInt32(g >> 4) << 4) | UInt32(b >> 4)
                counts[key, default: 0] += 1
            }
        }

        guard let dominant = counts.max(by: { $0.value < $1.value })?.key else { return .fallback }

        let pastel = 0.4
        let r = Double((dominant >> 8) & 0xF) / 15.0
        let g = Double((dominant >> 4) & 0xF) / 15.0
        let b = Double(dominant & 0xF) / 15.0
        return SpriteColor(
            red: UInt8((r + (1 - r) * pastel) * 255),
            green: UInt8((g + (1 - g) * pastel) * 255),
            blue: UInt8((b + (1 - b) * pastel) * 255)
        )
    }
}
