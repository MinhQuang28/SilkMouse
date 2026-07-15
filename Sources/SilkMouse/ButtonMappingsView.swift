import SwiftUI

/// Button mappings (Settings ▸ Buttons). Add a mapping by clicking your actual mouse button into the
/// capture field (-style), then assign an action — no guessing button numbers.
struct ButtonMappingsView: View {
    @EnvironmentObject var store: ConfigStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ButtonCaptureField(onCapture: addMapping)

            if store.config.mappings.isEmpty {
                ContentUnavailableView("No mappings", systemImage: "computermouse",
                                       description: Text("Click the field above with a side button to start."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach($store.config.mappings) { $mapping in
                        MappingRow(mapping: $mapping) { delete(mapping.id) }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    /// Add a mapping for a freshly-captured button (ignore left/right click, and duplicates).
    private func addMapping(button: Int) {
        guard button >= 3 else { return } // don't let users break left/right click
        guard !store.config.mappings.contains(where: { $0.buttonNumber == button }) else { return }
        store.config.mappings.append(ButtonMapping(buttonNumber: button, action: .spaceLeft))
    }

    private func delete(_ id: UUID) {
        store.config.mappings.removeAll { $0.id == id }
    }
}

/// One row: captured button (fixed label) + action control + delete.
private struct MappingRow: View {
    @Binding var mapping: ButtonMapping
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Label("Button \(mapping.buttonNumber)", systemImage: "computermouse.fill")
                .frame(width: 110, alignment: .leading)

            Image(systemName: "arrow.right").foregroundStyle(.secondary)

            ShortcutControl(action: $mapping.action)

            Spacer()

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }
}
