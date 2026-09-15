import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation
@testable import Vidrio

struct ColorExtractorTests {
    /// Builds a 4x4 solid-color CGImage, matching get_color.py's math by hand.
    private func solidImage(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) -> CGImage {
        let width = 4, height = 4, bpp = 4
        var pixels = [UInt8](repeating: 0, count: width * height * bpp)
        for i in stride(from: 0, to: pixels.count, by: bpp) {
            pixels[i] = r; pixels[i + 1] = g; pixels[i + 2] = b; pixels[i + 3] = a
        }
        let ctx = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * bpp,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return ctx.makeImage()!
    }

    @Test func testPastelFactorLightensDominantColor() {
        let color = ColorExtractor.dominantColor(for: solidImage(r: 255, g: 0, b: 0))
        // pastel factor 0.4: channel' = channel + (255 - channel) * 0.4
        #expect(color.red == 255)
        #expect(color.green == 102) // 0 + 255*0.4, quantized to 4 bits first (0 stays 0 -> 102)
        #expect(color.blue == 102)
    }

    @Test func testTransparentPixelsAreIgnored() {
        // Fully transparent red should fall back rather than being counted.
        let color = ColorExtractor.dominantColor(for: solidImage(r: 255, g: 0, b: 0, a: 0))
        #expect(color == .fallback)
    }

    @Test func testNearBlackPixelsAreIgnored() {
        let color = ColorExtractor.dominantColor(for: solidImage(r: 10, g: 10, b: 10))
        #expect(color == .fallback)
    }
}

struct ImagePipelineTests {
    private func writePNG(r: UInt8, g: UInt8, b: UInt8, size: Int = 8) throws -> URL {
        let bpp = 4
        var pixels = [UInt8](repeating: 0, count: size * size * bpp)
        for i in stride(from: 0, to: pixels.count, by: bpp) {
            pixels[i] = r; pixels[i + 1] = g; pixels[i + 2] = b; pixels[i + 3] = 255
        }
        let ctx = CGContext(
            data: &pixels, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size * bpp,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let image = ctx.makeImage()!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sprite-\(UUID().uuidString).png")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        return url
    }

    @Test func testStaticPNGKeepsNativeResolution() throws {
        let url = try writePNG(r: 200, g: 100, b: 50, size: 8)
        defer { try? FileManager.default.removeItem(at: url) }

        let rendered = try #require(ImagePipeline.render(fileAt: url, staticFrameOnly: true))
        #expect(rendered.nativeSize == CGSize(width: 8, height: 8))
        #expect(!rendered.isAnimated)

        let source = CGImageSourceCreateWithData(rendered.data as CFData, nil)!
        let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        #expect(decoded.width == 8) // SwiftTerm enlarges it with nearest-neighbor sampling
        #expect(decoded.height == 8)
    }

    private func writeAnimatedGIF(frames: Int, size: Int = 6) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sprite-\(UUID().uuidString).gif")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames, nil)!
        for f in 0..<frames {
            var pixels = [UInt8](repeating: 0, count: size * size * 4)
            for i in stride(from: 0, to: pixels.count, by: 4) {
                pixels[i] = UInt8(f * 60); pixels[i + 1] = 120; pixels[i + 3] = 255
            }
            let ctx = CGContext(
                data: &pixels, width: size, height: size,
                bitsPerComponent: 8, bytesPerRow: size * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        }
        #expect(CGImageDestinationFinalize(dest))
        return url
    }

    @Test func testAnimatedGIFPassesThroughUnchanged() throws {
        let url = try writeAnimatedGIF(frames: 3)
        defer { try? FileManager.default.removeItem(at: url) }

        let rendered = try #require(ImagePipeline.render(fileAt: url, staticFrameOnly: false))
        #expect(rendered.isAnimated)
        #expect(rendered.nativeSize == CGSize(width: 6, height: 6))
        #expect(rendered.data == (try Data(contentsOf: url)))

        let still = try #require(ImagePipeline.render(fileAt: url, staticFrameOnly: true))
        #expect(!still.isAnimated)
        let source = CGImageSourceCreateWithData(still.data as CFData, nil)!
        #expect(CGImageSourceGetCount(source) == 1)
    }

    @Test func testCacheRecomputesWhenTheFileChanges() throws {
        let url = try writePNG(r: 200, g: 100, b: 50, size: 8)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ImagePipeline.render(fileAt: url, staticFrameOnly: true)?.nativeSize == CGSize(width: 8, height: 8))

        let replacement = try writePNG(r: 10, g: 200, b: 10, size: 12)
        defer { try? FileManager.default.removeItem(at: replacement) }
        try FileManager.default.removeItem(at: url)
        try FileManager.default.copyItem(at: replacement, to: url)
        #expect(ImagePipeline.render(fileAt: url, staticFrameOnly: true)?.nativeSize == CGSize(width: 12, height: 12))
    }
}

struct GreetingRendererTests {
    @Test func testRenderEmitsAnITerm2InlineImageSequence() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sprite-\(UUID().uuidString).png")
        let bpp = 4
        var pixels = [UInt8](repeating: 0, count: 8 * 8 * bpp)
        for i in stride(from: 0, to: pixels.count, by: bpp) { pixels[i] = 255; pixels[i + 3] = 255 }
        let ctx = CGContext(
            data: &pixels, width: 8, height: 8,
            bitsPerComponent: 8, bytesPerRow: 8 * bpp,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(dest))
        defer { try? FileManager.default.removeItem(at: url) }

        let bytes = GreetingRenderer.render(spriteURL: url, displayMode: .image, shellExecutable: "/bin/zsh")
        let output = String(decoding: bytes, as: UTF8.self)

        #expect(output.contains("\u{1B}]1337;File=inline=1;"))
        #expect(output.contains("\u{07}"))
        #expect(output.contains("sh")) // shell key from SystemInfo
        #expect(output.contains("zsh"))
    }
}
