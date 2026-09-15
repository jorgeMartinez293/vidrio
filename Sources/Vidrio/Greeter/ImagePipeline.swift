import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Prepares a sprite file for the OSC 1337 payload, replacing sereno's ImageMagick step.
/// No upscaling: SwiftTerm draws inline images with nearest-neighbor sampling whenever it
/// enlarges them, so pixel art stays crisp at any size straight from the native file, and
/// larger images still get smooth filtering when shrunk.
enum ImagePipeline {
    struct RenderedSprite {
        /// Encoded file bytes ready for the OSC 1337 payload — the original file for an
        /// animated GIF, PNG for a single still frame, GIF for other animated formats.
        let data: Data
        /// Native pixel size of the source frame, used to compute the sprite's
        /// terminal-cell footprint.
        let nativeSize: CGSize
        let isAnimated: Bool
    }

    private static let cache = SpriteFileCache<RenderedSprite>()

    static func render(fileAt url: URL, staticFrameOnly: Bool) -> RenderedSprite? {
        cache.value(for: url, variant: staticFrameOnly ? "static" : "animated") {
            renderUncached(fileAt: url, staticFrameOnly: staticFrameOnly)
        }
    }

    private static func renderUncached(fileAt url: URL, staticFrameOnly: Bool) -> RenderedSprite? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let sourceFrameCount = CGImageSourceGetCount(source)
        let frameCount = staticFrameOnly ? min(1, sourceFrameCount) : sourceFrameCount
        guard frameCount > 0, let firstFrame = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        let nativeSize = CGSize(width: firstFrame.width, height: firstFrame.height)

        if frameCount <= 1 {
            guard let png = encodePNG(firstFrame) else { return nil }
            return RenderedSprite(data: png, nativeSize: nativeSize, isAnimated: false)
        }

        // SwiftTerm decodes GIFs itself, so an animated GIF goes through byte-for-byte.
        if let type = CGImageSourceGetType(source) as String?, UTType(type)?.conforms(to: .gif) == true,
           let data = try? Data(contentsOf: url) {
            return RenderedSprite(data: data, nativeSize: nativeSize, isAnimated: true)
        }

        var frames: [(image: CGImage, delay: Double)] = []
        for i in 0..<frameCount {
            guard let frame = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
            frames.append((frame, frameDelay(source, index: i)))
        }
        guard !frames.isEmpty, let gif = encodeAnimatedGIF(frames) else { return nil }
        return RenderedSprite(data: gif, nativeSize: nativeSize, isAnimated: true)
    }

    private static func frameDelay(_ source: CGImageSource, index: Int) -> Double {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else { return 0.1 }
        for (dictionaryKey, unclampedKey, clampedKey) in [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
        ] {
            guard let dictionary = properties[dictionaryKey] as? [CFString: Any] else { continue }
            if let delay = (dictionary[unclampedKey] ?? dictionary[clampedKey]) as? Double { return delay }
        }
        return 0.1
    }

    private static func encodePNG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    private static func encodeAnimatedGIF(_ frames: [(image: CGImage, delay: Double)]) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frames.count, nil) else { return nil }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for frame in frames {
            let frameProperties: [CFString: Any] = [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: frame.delay] as CFDictionary
            ]
            CGImageDestinationAddImage(dest, frame.image, frameProperties as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
