import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// The Greeter panel: pick a sprite on the left, see what the greeting will
/// look like on the right, tweak the options along the bottom, press
/// "Guardar". Nothing is written to disk until then — picking a sprite only
/// updates the live preview.
///
/// This is a deliberately plain replacement for the earlier split-view panel:
/// a single window with an ordinary `HStack`, cached still thumbnails, and a
/// preview drawn with SwiftUI text instead of a live embedded terminal. Every
/// option the old panel exposed is still here; only the machinery is gone.
struct SimpleGreeterView: View {
    @StateObject private var spriteManager = SpriteManager()

    @State private var config = GreeterConfigStore.load()
    @State private var selectedSprite: Sprite?
    @State private var isRandomMode = false
    @State private var searchText = ""
    @State private var accentColor = Self.defaultAccent
    @State private var showFieldsPicker = false
    @State private var isOnBattery = SystemInfo.isOnBattery()
    @State private var saveFailed = false
    @State private var isDropTargeted = false

    /// System-info values, read once on appear off the main thread. The
    /// preview only formats them, so switching fields or sprites never
    /// re-queries sysctl/disk/Homebrew.
    @State private var infoValues: [InfoField: String] = [:]

    /// A sprite drawn once when random mode is entered, so the preview stays
    /// still instead of re-rolling on every redraw.
    @State private var randomSample: Sprite?

    /// What's currently on disk (config.json), so we can tell whether the live
    /// selection still matches it — drives the Guardar button's enabled state.
    @State private var savedSelectedFilename: String?
    @State private var savedDisplayMode: DisplayMode = .auto
    @State private var savedFields: [InfoField] = InfoField.defaults
    @State private var savedBulletColorHex: String?

    private static let defaultAccent = Color(red: 0.85, green: 0.55, blue: 0.55)

    private var filtered: [Sprite] {
        searchText.isEmpty ? spriteManager.sprites
        : spriteManager.sprites.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var previewSprite: Sprite? {
        isRandomMode ? randomSample : selectedSprite
    }

    private var isDirty: Bool {
        let currentSprite = isRandomMode ? nil : selectedSprite?.filename
        return currentSprite != savedSelectedFilename
            || config.displayMode != savedDisplayMode
            || config.enabledFields != savedFields
            || config.bulletColorHex != savedBulletColorHex
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                spriteList
                Divider()
                previewPanel
                    .frame(width: 300)
            }
            Divider()
            controlBar
        }
        .frame(minWidth: 760, minHeight: 460)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showFieldsPicker) {
            InfoFieldsPickerView(enabledFields: $config.enabledFields, accentColor: accentColor)
        }
        .onAppear {
            restoreSelection()
            loadSystemInfo()
        }
    }

    // MARK: - Sprite list

    private var spriteList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Buscar", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                Button {
                    presentImportPanel()
                } label: {
                    Image(systemName: "plus")
                }
                .help("Añadir sprites desde el disco")
            }
            .padding(10)

            Divider()

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 8)], spacing: 8) {
                    if searchText.isEmpty {
                        SpriteCard(title: "Aleatorio",
                                   isSelected: isRandomMode,
                                   accentColor: accentColor) {
                            Image(systemName: "dice.fill")
                                .font(.system(size: 24))
                                .foregroundColor(isRandomMode ? accentColor : .secondary)
                        }
                        .onTapGesture { selectRandom() }
                    }

                    ForEach(filtered) { sprite in
                        SpriteCard(title: sprite.name,
                                   isSelected: !isRandomMode && selectedSprite == sprite,
                                   accentColor: accentColor) {
                            SpriteThumbnail(url: sprite.url)
                        }
                        .onTapGesture { select(sprite) }
                        .contextMenu {
                            Button("Eliminar", role: .destructive) { delete(sprite) }
                        }
                    }
                }
                .padding(10)

                if filtered.isEmpty {
                    Text(searchText.isEmpty ? "No hay sprites todavía" : "Sin resultados")
                        .font(.callout).foregroundColor(.secondary)
                        .padding(.top, 30)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)

            Divider()
            HStack {
                Text("\(filtered.count) sprites")
                Spacer()
                Text(isDropTargeted ? "Suelta para añadir" : "Arrastra .gif aquí")
            }
            .font(.caption).foregroundColor(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .frame(minWidth: 300)
    }

    // MARK: - Preview

    private var previewPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Vista previa").font(.caption).foregroundColor(.secondary)
                Spacer()
                Text(showsGIF ? "GIF animado" : "Imagen estática")
                    .font(.caption).foregroundColor(.secondary)
            }

            if let sprite = previewSprite {
                AnimatedSpriteView(url: sprite.url, animates: showsGIF)
                    .frame(height: 110)
                    .frame(maxWidth: .infinity)
            } else {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 44)).foregroundColor(.white.opacity(0.18))
                    .frame(height: 110).frame(maxWidth: .infinity)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(config.enabledFields) { field in
                        HStack(alignment: .top, spacing: 5) {
                            Text("\u{25CF} \(field.key)").foregroundColor(accentColor)
                            Text(infoValues[field] ?? "…").foregroundColor(.white.opacity(0.85))
                        }
                    }
                    HStack(spacing: 5) {
                        Text("\u{25CF}")
                        Text(homePath).lineLimit(1).truncationMode(.head)
                    }
                    .foregroundColor(accentColor)
                    .padding(.top, 6)
                }
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(red: 0.10, green: 0.10, blue: 0.13))
    }

    private var showsGIF: Bool {
        switch config.displayMode {
        case .gif: return true
        case .image: return false
        case .auto: return !isOnBattery
        }
    }

    private var homePath: String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    // MARK: - Controls

    private var controlBar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $config.displayMode) {
                ForEach(DisplayMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 280)

            Button {
                showFieldsPicker = true
            } label: {
                Label("Información", systemImage: "list.bullet.rectangle")
            }
            .help("Elige qué datos del sistema se muestran junto al sprite")

            ColorPicker("", selection: bulletColorBinding, supportsOpacity: false)
                .labelsHidden()
                .help("Color del punto y del prompt")

            if config.bulletColorHex != nil {
                Button {
                    config.bulletColorHex = nil
                    applyColor()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("Usar el color del sprite")
            }

            Spacer()

            if saveFailed {
                Label("Error al guardar", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundColor(.orange)
            }

            Button("Guardar") { persist() }
                .buttonStyle(.borderedProminent)
                .tint(accentColor)
                .disabled(!isDirty)
                .help("Aplica el sprite y color actuales, incluidas las ventanas de vidrio ya abiertas")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.bar)
    }

    /// The color picker's binding: the active bullet/prompt color right now,
    /// whether that's the user's override or the sprite's dominant color.
    private var bulletColorBinding: Binding<Color> {
        Binding(
            get: { accentColor },
            set: { newColor in
                config.bulletColorHex = Self.hex(from: newColor)
                accentColor = newColor
            }
        )
    }

    private static func hex(from color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor(color)
        let r = UInt8((max(0, min(1, ns.redComponent)) * 255).rounded())
        let g = UInt8((max(0, min(1, ns.greenComponent)) * 255).rounded())
        let b = UInt8((max(0, min(1, ns.blueComponent)) * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    // MARK: - Actions

    private func select(_ sprite: Sprite) {
        isRandomMode = false
        selectedSprite = sprite
        applyColor()
    }

    private func selectRandom() {
        isRandomMode = true
        selectedSprite = nil
        randomSample = spriteManager.sprites.randomElement()
        applyColor()
    }

    private func delete(_ sprite: Sprite) {
        if selectedSprite == sprite { selectRandom() }
        SpriteThumbnailCache.invalidate(sprite.url)
        spriteManager.deleteSprite(sprite)
    }

    private func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.gif, .png, .jpeg, .webP]
        panel.begin { response in
            guard response == .OK else { return }
            spriteManager.importSprites(from: panel.urls)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }

        let group = DispatchGroup()
        let collected = DroppedURLs()

        for provider in fileProviders {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                defer { group.leave() }
                let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                if let url { collected.append(url) }
            }
        }

        group.notify(queue: .main) { spriteManager.importSprites(from: collected.urls) }
        return true
    }

    // MARK: - State

    private func restoreSelection() {
        savedSelectedFilename = config.selectedSprite
        savedDisplayMode = config.displayMode
        savedFields = config.enabledFields
        savedBulletColorHex = config.bulletColorHex
        if let saved = config.selectedSprite,
           let sprite = spriteManager.sprites.first(where: { $0.filename == saved }) {
            selectedSprite = sprite
        } else {
            isRandomMode = true
            randomSample = spriteManager.sprites.randomElement()
        }
        applyColor()
    }

    private func loadSystemInfo() {
        let shell = "/bin/zsh"
        DispatchQueue.global(qos: .userInitiated).async {
            let fields = InfoField.allCases
            let lines = SystemInfo.lines(shellExecutable: shell, fields: fields)
            let values = Dictionary(uniqueKeysWithValues: zip(fields, lines.map(\.value)))
            DispatchQueue.main.async { infoValues = values }
        }
    }

    /// Resolves the color driving the accent, the info-line bullets and the
    /// prompt: the user's override if set, otherwise the current sprite's
    /// dominant color.
    private func applyColor() {
        if let hex = config.bulletColorHex, let custom = SpriteColor(hex: hex) {
            accentColor = custom.color
            return
        }
        guard let sprite = previewSprite else {
            accentColor = Self.defaultAccent
            return
        }
        if let cached = SpriteThumbnailCache.cachedColor(for: sprite.url) {
            accentColor = cached
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let color = ColorExtractor.dominantColor(for: sprite.url).color
            DispatchQueue.main.async {
                SpriteThumbnailCache.cacheColor(color, for: sprite.url)
                if previewSprite == sprite { accentColor = color }
            }
        }
    }

    /// Save button: writes the selection to config.json. Already-open vidrio
    /// windows watch that file (AppDelegate's ConfigWatcher) and pick the
    /// change up on their own within about half a second.
    private func persist() {
        config.selectedSprite = isRandomMode ? nil : selectedSprite?.filename
        do {
            try GreeterConfigStore.save(config)
            savedSelectedFilename = config.selectedSprite
            savedDisplayMode = config.displayMode
            savedFields = config.enabledFields
            savedBulletColorHex = config.bulletColorHex
            saveFailed = false
        } catch {
            saveFailed = true
        }
    }
}

/// The URLs a drop is still loading, gathered from the several completion
/// handlers `loadItem` calls on arbitrary queues.
private final class DroppedURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    func append(_ url: URL) {
        lock.lock(); storage.append(url); lock.unlock()
    }

    var urls: [URL] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

// MARK: - Grid card

/// One tile in the sprite grid: a rounded well with `content` inside and a
/// caption underneath. No hover tracking and no shadows — the old grid
/// re-rendered every visible cell on each mouse move.
private struct SpriteCard<Content: View>: View {
    let title: String
    let isSelected: Bool
    let accentColor: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? accentColor.opacity(0.18) : Color.primary.opacity(0.05))
                content.padding(6)
            }
            .frame(width: 72, height: 62)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? accentColor : .clear, lineWidth: 2)
            )

            Text(title)
                .font(.caption2)
                .foregroundColor(isSelected ? accentColor : .primary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Thumbnails

/// A still, pixel-exact thumbnail of a sprite file, decoded once per path and
/// kept in an `NSCache`. The old grid built an `NSImageView` per cell and
/// re-read the file from disk on every SwiftUI update pass.
private struct SpriteThumbnail: View {
    let url: URL
    var maxPixelSize: Int = SpriteThumbnailCache.thumbnailMaxPixelSize

    var body: some View {
        if let image = SpriteThumbnailCache.image(for: url, maxPixelSize: maxPixelSize) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
        } else {
            Image(systemName: "questionmark.square.dashed")
                .foregroundColor(.secondary)
        }
    }
}

/// The preview's sprite, animated by AppKit itself when the display mode asks
/// for it — an `NSImageView` plays a multi-frame GIF on its own, so this costs
/// one view and one decoded image, not a frame timer of ours.
private struct AnimatedSpriteView: NSViewRepresentable {
    let url: URL
    let animates: Bool

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.imageFrameStyle = .none
        view.wantsLayer = true
        // Sprites are pixel art: scale them with hard edges, not blurred ones.
        view.layer?.magnificationFilter = .nearest
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        configure(view)
        return view
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        configure(nsView)
    }

    /// Reassigning the image restarts the animation, so only touch it when the
    /// sprite actually changed.
    private func configure(_ view: NSImageView) {
        let image = SpriteThumbnailCache.fullImage(for: url)
        if view.image !== image { view.image = image }
        view.animates = animates
    }
}

/// Process-wide caches for the Greeter panel: decoded thumbnails and the
/// dominant color of each sprite (which costs a full image decode to compute).
@MainActor
private enum SpriteThumbnailCache {
    static let thumbnailMaxPixelSize = 96

    private static let images = NSCache<NSString, NSImage>()
    private static let fullImages = NSCache<NSString, NSImage>()
    private static var colors: [String: Color] = [:]

    static func image(for url: URL, maxPixelSize: Int) -> NSImage? {
        let key = "\(url.path)@\(maxPixelSize)" as NSString
        if let hit = images.object(forKey: key) { return hit }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
              ] as CFDictionary)
        else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        images.setObject(image, forKey: key)
        return image
    }

    /// The sprite at its native size, with every GIF frame intact so an
    /// `NSImageView` can animate it.
    static func fullImage(for url: URL) -> NSImage? {
        let key = url.path as NSString
        if let hit = fullImages.object(forKey: key) { return hit }
        guard let image = NSImage(contentsOf: url) else { return nil }
        fullImages.setObject(image, forKey: key)
        return image
    }

    static func invalidate(_ url: URL) {
        images.removeObject(forKey: "\(url.path)@\(thumbnailMaxPixelSize)" as NSString)
        fullImages.removeObject(forKey: url.path as NSString)
        colors[url.path] = nil
    }

    static func cachedColor(for url: URL) -> Color? { colors[url.path] }
    static func cacheColor(_ color: Color, for url: URL) { colors[url.path] = color }
}
