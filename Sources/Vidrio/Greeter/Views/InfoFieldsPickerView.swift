import SwiftUI

/// Sheet that lets the user pick which system-info lines show next to the
/// sprite, and reorder the ones they keep. Mirrors `PackStoreView`'s layout
/// but edits `enabledFields` live, the same way the sprite grid edits
/// `selectedSprite` — nothing is written to disk until "Guardar" is pressed.
struct InfoFieldsPickerView: View {
    @Binding var enabledFields: [InfoField]
    let accentColor: Color
    @Environment(\.dismiss) private var dismiss

    private var availableFields: [InfoField] {
        InfoField.allCases.filter { !enabledFields.contains($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Information to show", systemImage: "list.bullet.rectangle")
                    .font(.headline)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)
            .background(.bar)

            Divider()

            List {
                Section("Showing (drag to reorder)") {
                    if enabledFields.isEmpty {
                        Text("Nothing selected")
                            .foregroundColor(.secondary)
                    }
                    ForEach(enabledFields) { field in
                        fieldRow(field, isEnabled: true)
                    }
                    .onMove { indices, newOffset in
                        enabledFields.move(fromOffsets: indices, toOffset: newOffset)
                    }
                }

                if !availableFields.isEmpty {
                    Section("Available") {
                        ForEach(availableFields) { field in
                            fieldRow(field, isEnabled: false)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .frame(width: 420, height: 500)
    }

    /// Only the trailing icon is a `Button` — wrapping the whole row would let its
    /// tap gesture swallow the drag that `List`'s `onMove` reordering relies on.
    private func fieldRow(_ field: InfoField, isEnabled: Bool) -> some View {
        HStack {
            Label(field.title, systemImage: field.icon)
            Spacer()
            Button {
                if isEnabled {
                    enabledFields.removeAll { $0 == field }
                } else {
                    enabledFields.append(field)
                }
            } label: {
                Image(systemName: isEnabled ? "minus.circle.fill" : "plus.circle.fill")
                    .foregroundColor(isEnabled ? .secondary : accentColor)
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
    }
}
