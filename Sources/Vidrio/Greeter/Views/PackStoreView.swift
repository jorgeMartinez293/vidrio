import SwiftUI

/// Sheet that lists the themed sprite packs published alongside vidrio and
/// lets the user download them into ~/.config/sereno/sprites.
struct PackStoreView: View {
    @ObservedObject var spriteManager: SpriteManager
    let accentColor: Color
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = PackStore()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Packs de sprites", systemImage: "shippingbox")
                    .font(.headline)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)
            .background(.bar)

            Divider()

            switch store.loadState {
            case .idle, .loading:
                Spacer()
                ProgressView("Loading catalog…")
                Spacer()
            case .failed:
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 36)).foregroundColor(.secondary)
                    Text("Couldn’t load the catalog")
                        .foregroundColor(.secondary)
                    Button("Retry") { Task { await store.loadManifest() } }
                }
                Spacer()
            case .loaded:
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(store.packs) { pack in
                            PackRow(
                                pack: pack,
                                state: store.packStates[pack.id] ?? .notInstalled,
                                accentColor: accentColor,
                                store: store
                            ) {
                                Task { await store.download(pack, into: spriteManager) }
                            }
                        }
                    }
                    .padding(14)
                }
            }

            Divider()
            Text("You can also drag your own .gif or .png files onto the sprite list")
                .font(.caption).foregroundColor(.secondary)
                .padding(.vertical, 8)
        }
        .frame(width: 440, height: 480)
        .task { await store.loadManifest() }
    }
}

private struct PackRow: View {
    let pack: SpritePack
    let state: PackStore.PackState
    let accentColor: Color
    let store: PackStore
    let onDownload: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                ForEach(pack.sprites.prefix(3), id: \.self) { file in
                    AsyncImage(url: store.spriteURL(pack: pack, file: file)) { image in
                        image.resizable().interpolation(.none).scaledToFit()
                    } placeholder: {
                        Color.primary.opacity(0.04)
                    }
                    .frame(width: 30, height: 30)
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))

            VStack(alignment: .leading, spacing: 2) {
                Text(pack.name).fontWeight(.semibold)
                Text(pack.description)
                    .font(.caption).foregroundColor(.secondary)
                Text("\(pack.sprites.count) sprites")
                    .font(.caption2).foregroundColor(.secondary)
            }

            Spacer()

            switch state {
            case .notInstalled:
                Button {
                    onDownload()
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(accentColor)
            case .downloading(let done, let total):
                HStack(spacing: 6) {
                    ProgressView(value: Double(done), total: Double(total))
                        .frame(width: 60)
                    Text("\(done)/\(total)")
                        .font(.caption2).monospacedDigit().foregroundColor(.secondary)
                }
            case .installed:
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundColor(.green)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.03)))
    }
}
