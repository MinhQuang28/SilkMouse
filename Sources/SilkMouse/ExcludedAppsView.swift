import SwiftUI
import UniformTypeIdentifiers

/// Settings section for the scroll-exclusion list: apps where smoothing is bypassed so the wheel
/// stays a native legacy notch (needed by horizontal-only views, e.g. Nimble Commander's panels).
struct ExcludedAppsView: View {
    @EnvironmentObject var store: ConfigStore

    var body: some View {
        AppListSection(
            title: "Excluded apps",
            emptyLabel: "No excluded apps",
            addPrompt: "Exclude",
            footer: "Scroll smoothing is turned off while the pointer is over these apps — the wheel behaves natively there. Reverse and scroll speed still apply. Terminal apps (Terminal, iTerm2, kitty, WezTerm, Ghostty, Alacritty, …) are always excluded: they translate scroll pixels into wheel reports, so a smooth glide would jump many text lines per notch. Warp is not excluded — it renders pixel scrolling natively.",
            bundleIDs: $store.config.excludedBundleIDs)
    }
}

/// Settings section for the axis-swap list: apps where the wheel's vertical motion scrolls
/// HORIZONTALLY (purpose-built for horizontal-first browsers like Nimble Commander's Brief
/// panels). Unlike exclusion, smoothing keeps working — we transpose the axes ourselves.
struct TransposedAppsView: View {
    @EnvironmentObject var store: ConfigStore

    var body: some View {
        AppListSection(
            title: "Vertical → horizontal apps",
            emptyLabel: "No axis-swap apps",
            addPrompt: "Add",
            footer: "While the pointer is over these apps, vertical wheel scrolling scrolls horizontally (and tilt scrolls vertically). Smoothing, reverse and speed all still apply — made for Nimble Commander's Brief mode and other horizontal-first views.",
            bundleIDs: $store.config.verticalToHorizontalBundleIDs)
    }
}

/// One reusable per-app list section: rows with app icon/name, remove buttons, an add-app picker.
private struct AppListSection: View {
    let title: String
    let emptyLabel: String
    let addPrompt: String
    let footer: String
    @Binding var bundleIDs: [String]

    var body: some View {
        Section(title) {
            if bundleIDs.isEmpty {
                Text(emptyLabel)
                    .foregroundStyle(.secondary)
            }
            ForEach(bundleIDs, id: \.self) { bundleID in
                HStack {
                    AppRow(bundleID: bundleID)
                    Spacer()
                    Button {
                        bundleIDs.removeAll { $0 == bundleID }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove from this list")
                }
            }
            Button("Add App…", action: addApp)
            Text(footer)
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
        panel.prompt = addPrompt
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let id = Bundle(url: url)?.bundleIdentifier,
                  !bundleIDs.contains(id) else { continue }
            bundleIDs.append(id)
        }
    }
}

/// One listed app: icon + display name when the app is installed, otherwise the raw bundle ID.
private struct AppRow: View {
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
