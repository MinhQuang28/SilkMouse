import Foundation
import Combine

/// Loads/saves `AppConfig` as JSON in Application Support and pushes changes to the engine.
/// `@MainActor` so SwiftUI can bind to it directly.
@MainActor
final class ConfigStore: ObservableObject {

    static let shared = ConfigStore()

    @Published var config: AppConfig {
        didSet {
            save()
            EventTapEngine.shared.reload(config)
        }
    }

    private let fileURL: URL

    private init() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Mousse", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("config.json")

        // One-time migration: the app was called SilkMouse (and QmouseFix before that) — adopt
        // the newest prior config so a rename doesn't silently reset anyone's settings.
        // (Copy, not move: harmless leftover.)
        if !FileManager.default.fileExists(atPath: fileURL.path),
           let legacy = ["SilkMouse/config.json", "QmouseFix/config.json"]
               .map({ support.appendingPathComponent($0) })
               .first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            try? FileManager.default.copyItem(at: legacy, to: fileURL)
        }

        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder().decode(AppConfig.self, from: data) {
            config = loaded
        } else {
            config = AppConfig()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(config) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
