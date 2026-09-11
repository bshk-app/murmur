import Foundation
import WidgetKit

/// A dated snapshot, never a promise that a suspended process is still resident.
struct MurMurWidgetState: Codable, Equatable {
    var source: String = "ru"
    var target: String = "en"
    var status: String = "Prepare dictation"
    var updatedAt: Date = .now
    static var file: URL? { StoragePaths.shared?.appendingPathComponent("widget-state.json") }
    static func read() -> Self {
        guard let file, let data = try? Data(contentsOf: file), let value = try? JSONDecoder().decode(Self.self, from: data) else { return .init() }
        return value
    }
    func save() {
        guard let file = Self.file, let data = try? JSONEncoder().encode(self) else { return }
        do {
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            WidgetCenter.shared.reloadTimelines(ofKind: "MurMurRecord")
        } catch { /* The main app remains usable before first unlock. */ }
    }
}

struct MurMurEntry: TimelineEntry {
    let date: Date
    var state: MurMurWidgetState = .read()
}
