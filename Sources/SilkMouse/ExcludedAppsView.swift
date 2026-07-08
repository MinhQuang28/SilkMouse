import SwiftUI
import UniformTypeIdentifiers

/// Settings section for the scroll-exclusion list: apps where smoothing is bypassed so the wheel
/// stays a native legacy notch (needed by horizontal-only views, e.g. Nimble Commander's panels).
struct ExcludedAppsView: View {
    @EnvironmentObject var store: ConfigStore

    var body: some View {
        Section("Excluded apps") {
            if store.config.excludedBundleIDs.isEmpty {
                Text("No excluded apps")
                    .foregroundStyle(.secondary)
            }
            ForEach(store.config.excludedBundleIDs, id: \.self) { bundleID in
                HStack {
                    ExcludedAppRow(bundleID: bundleID)
                    Spacer()
                    Button {
                        store.config.excludedBundleIDs.removeAll { $0 == bundleID }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove from exclusions")
                }
            }
            Button("Add App…", action: addApp)
            Text("Scroll smoothing is turned off while the pointer is over these apps — the wheel behaves natively there (fixes apps that scroll horizontally, like Nimble Commander). Reverse and scroll speed still apply.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Exclude"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let id = Bundle(url: url)?.bundleIdentifier,
                  !store.config.excludedBundleIDs.contains(id) else { continue }
            store.config.excludedBundleIDs.append(id)
        }
    }
}

/// One excluded app: icon + display name when the app is installed, otherwise the raw bundle ID.
private struct ExcludedAppRow: View {
    let bundleID: String

    var body: some View {
        HStack(spacing: 6) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable().frame(width: 18, height: 18)
                Text(FileManager.default.displayName(atPath: url.path))
            } else {
                Image(systemName: "questionmark.app").frame(width: 18, height: 18)
                Text(bundleID).foregroundStyle(.secondary)
            }
        }
    }
}
