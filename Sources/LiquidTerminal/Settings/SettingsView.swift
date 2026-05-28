import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    private var s: Binding<TerminalSettings> { $viewModel.settings }

    var body: some View {
        Form {
            Section("Tamaño (al abrir)") {
                Stepper(value: s.cols, in: TerminalSettings.colsRange) {
                    LabeledContent("Columnas", value: "\(viewModel.settings.cols)")
                }
                Stepper(value: s.rows, in: TerminalSettings.rowsRange) {
                    LabeledContent("Filas", value: "\(viewModel.settings.rows)")
                }
            }

            Section("Fondo") {
                Picker("Desenfoque", selection: s.blurMaterial) {
                    ForEach(BlurMaterial.allCases, id: \.self) { material in
                        Text(material.displayName).tag(material)
                    }
                }
                Toggle("Color de fondo", isOn: s.backgroundColorEnabled)
                if viewModel.settings.backgroundColorEnabled {
                    ColorPicker("Color", selection: viewModel.colorBinding(\.backgroundColor))
                    VStack(alignment: .leading) {
                        Text("Opacidad: \(Int(viewModel.settings.opacity * 100))%")
                        Slider(value: s.opacity, in: TerminalSettings.opacityRange)
                    }
                }
            }

            Section("Texto") {
                Picker("Fuente", selection: s.fontName) {
                    ForEach(viewModel.monospaceFonts, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                Stepper(value: s.fontSize, in: TerminalSettings.fontSizeRange, step: 1) {
                    LabeledContent("Tamaño", value: "\(Int(viewModel.settings.fontSize)) pt")
                }
                ColorPicker("Color del texto", selection: viewModel.colorBinding(\.textColor))
                ColorPicker("Color del cursor", selection: viewModel.colorBinding(\.cursorColor))
            }

            Section("Ventana") {
                VStack(alignment: .leading) {
                    Text("Radio de esquinas: \(Int(viewModel.settings.cornerRadius)) pt")
                    Slider(value: s.cornerRadius, in: TerminalSettings.cornerRadiusRange)
                }
            }

            Section {
                Button("Restaurar valores por defecto") {
                    viewModel.reset()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 560)
    }
}
