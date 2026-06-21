import SwiftUI

/// Editable list of button → action mappings (Settings ▸ Buttons).
struct ButtonMappingsView: View {
    @EnvironmentObject var store: ConfigStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Button mappings").font(.headline)
                Spacer()
                Button { addMapping() } label: { Label("Add", systemImage: "plus") }
            }

            if store.config.mappings.isEmpty {
                ContentUnavailableView("No mappings", systemImage: "computermouse",
                                       description: Text("Add a mapping to remap a mouse button."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach($store.config.mappings) { $mapping in
                        MappingRow(mapping: $mapping) { delete(mapping.id) }
                    }
                }
                .listStyle(.inset)
            }

            Text("Side buttons (4, 5) are the usual targets. The action fires on button press.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Append a mapping on the lowest unused button number.
    private func addMapping() {
        let used = Set(store.config.mappings.map(\.buttonNumber))
        let next = (3...20).first { !used.contains($0) } ?? 4
        store.config.mappings.append(ButtonMapping(buttonNumber: next, action: .spaceLeft))
    }

    private func delete(_ id: UUID) {
        store.config.mappings.removeAll { $0.id == id }
    }
}

/// One editable row: button-number picker + action picker + delete.
private struct MappingRow: View {
    @Binding var mapping: ButtonMapping
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Picker("", selection: $mapping.buttonNumber) {
                ForEach(3...9, id: \.self) { Text("Button \($0)").tag($0) }
            }
            .labelsHidden()
            .frame(width: 120)

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
