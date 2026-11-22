import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    private var s: Binding<TerminalSettings> { $viewModel.settings }

    /// On/off view of `blurMaterial`. Turning it back on picks the default
    /// material, so the setting still means the same on an older macOS.
    private var blurEnabled: Binding<Bool> {
        Binding(
            get: { viewModel.settings.blurMaterial != .none },
            set: { viewModel.settings.blurMaterial = $0 ? TerminalSettings.defaults.blurMaterial : .none }
        )
    }

    var body: some View {
        Form {
            Section("Size (on open)") {
                Stepper(value: s.cols, in: TerminalSettings.colsRange) {
                    LabeledContent("Columns", value: "\(viewModel.settings.cols)")
                }
                Stepper(value: s.rows, in: TerminalSettings.rowsRange) {
                    LabeledContent("Rows", value: "\(viewModel.settings.rows)")
                }
            }

            Section {
                Toggle("Match colors to greeter sprite", isOn: s.matchGreeterColors)
                Toggle("Custom attention ring color", isOn: viewModel.ringColorEnabled)
                if viewModel.settings.ringColor != nil {
                    ColorPicker("Ring color", selection: viewModel.ringColorBinding)
                }
            } header: {
                Text("Colors")
            } footer: {
                Text("Matching gives each pane a palette, cursor and ring based on its sprite. The ring marks panes with unread activity.")
            }

            Section("Background") {
                if BackdropView.supportsMaterials {
                    Picker("Blur", selection: s.blurMaterial) {
                        ForEach(BlurMaterial.allCases, id: \.self) { material in
                            Text(material.displayName).tag(material)
                        }
                    }
                } else {
                    // Liquid Glass has no materials to pick from.
                    Toggle("Blur", isOn: blurEnabled)
                }
                Toggle("Background color", isOn: s.backgroundColorEnabled)
                if viewModel.settings.backgroundColorEnabled {
                    ColorPicker("Color", selection: viewModel.colorBinding(\.backgroundColor))
                    VStack(alignment: .leading) {
                        Text("Opacity: \(Int(viewModel.settings.opacity * 100))%")
                        Slider(value: s.opacity, in: TerminalSettings.opacityRange)
                    }
                }
            }

            Section("Text") {
                Picker("Font", selection: s.fontName) {
                    ForEach(viewModel.monospaceFonts, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                Stepper(value: s.fontSize, in: TerminalSettings.fontSizeRange, step: 1) {
                    LabeledContent("Size", value: "\(Int(viewModel.settings.fontSize)) pt")
                }
                ColorPicker("Text color", selection: viewModel.colorBinding(\.textColor))
                ColorPicker("Cursor color", selection: viewModel.colorBinding(\.cursorColor))
                Toggle("Replace Claude Code's gray", isOn: viewModel.secondaryTextEnabled)
                if viewModel.settings.secondaryTextColor != nil {
                    ColorPicker("Secondary text color", selection: viewModel.secondaryTextBinding)
                }
                VStack(alignment: .leading) {
                    Text("Dim text brightness: \(Int(viewModel.settings.dimFactor * 100))%")
                    Slider(value: s.dimFactor, in: TerminalSettings.dimFactorRange)
                }
            }

            Section("History") {
                Stepper(value: s.scrollbackLines, in: TerminalSettings.scrollbackRange, step: 1000) {
                    LabeledContent("Lines per pane", value: "\(viewModel.settings.scrollbackLines)")
                }
            }

            Section {
                Toggle("Show Claude Code status on panes", isOn: viewModel.agentHooksEnabled)
                if let error = viewModel.hooksError {
                    Text(error).font(.caption).foregroundColor(.red)
                }
            } header: {
                Text("Agents")
            } footer: {
                Text("Adds hooks to ~/.claude/settings.json (a backup is kept next to it). Turning this off removes them.")
            }

            Section {
                Picker("Programs writing to the clipboard", selection: s.clipboardAccess) {
                    ForEach(ClipboardAccess.allCases, id: \.self) { access in
                        Text(access.displayName).tag(access)
                    }
                }
                TextField("Editor command", text: s.editorCommand, prompt: Text("code -g {file}:{line}:{column}"))
            } header: {
                Text("Clipboard and Links")
            } footer: {
                Text("⌘-click a file path to open it with this command. Leave it empty to use the default app.")
            }

            Section {
                Toggle("Enable quick terminal", isOn: s.quickTerminalEnabled)
                TextField("Shortcut", text: s.quickTerminalShortcut)
                    .disabled(!viewModel.settings.quickTerminalEnabled)
                if viewModel.settings.quickTerminalEnabled,
                   KeyCombo(viewModel.settings.quickTerminalShortcut)?.carbonKeyCode == nil {
                    Text("Not a valid shortcut").font(.caption).foregroundColor(.red)
                }
            } header: {
                Text("Quick Terminal")
            } footer: {
                Text("Drops a terminal from the top of the screen, from any app.")
            }

            Section {
                DisclosureGroup("Keyboard shortcuts") {
                    ForEach(ShortcutAction.allCases) { action in
                        ShortcutRow(action: action, text: viewModel.shortcutBinding(for: action))
                    }
                }
                Button("Reset Shortcuts") { viewModel.settings.shortcuts = [:] }
            } header: {
                Text("Shortcuts")
            } footer: {
                Text("Write them like cmd+shift+p, or as a two-step chord like ctrl+b c. Leave one empty to disable it.")
            }

            Section {
                Picker("Rearrange panes", selection: viewModel.rearrangeModifier) {
                    ForEach(DragModifier.allCases, id: \.self) { modifier in
                        Text(modifier.displayName).tag(modifier)
                    }
                }
                Picker("Swap panes", selection: viewModel.swapModifier) {
                    ForEach(DragModifier.allCases, id: \.self) { modifier in
                        Text(modifier.displayName).tag(modifier)
                    }
                }
            } header: {
                Text("Dragging Panes")
            } footer: {
                Text("Hold the key and drag a pane. The rearrange key also merges windows when you drag them by the top strip.")
            }

            Section {
                Button("Restore Defaults") {
                    viewModel.reset()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 800)
    }
}

private struct ShortcutRow: View {
    let action: ShortcutAction
    @Binding var text: String

    private var isValid: Bool {
        text.trimmingCharacters(in: .whitespaces).isEmpty || KeyBinding(text) != nil
    }

    var body: some View {
        LabeledContent(action.title.replacingOccurrences(of: "…", with: "")) {
            TextField("", text: $text, prompt: Text("Disabled"))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .foregroundColor(isValid ? .primary : .red)
                .frame(width: 170)
        }
    }
}
