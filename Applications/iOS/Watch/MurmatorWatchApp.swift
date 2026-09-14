import AppIntents
import SwiftUI

/// Exposes the recording intent to Shortcuts, which is what lets the Action
/// Button reach it.
struct MurmatorWatchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartWatchRecordingIntent(), phrases: ["Record a note with \(.applicationName)"],
                    shortTitle: "Record a note", systemImageName: "mic.fill")
    }
}

@main struct MurmatorWatchApp: App {
    @State private var sync: WatchSync
    @State private var recorder: WatchRecorder

    init() {
        let sync = WatchSync()
        let recorder = WatchRecorder()
        // An interrupted recording takes the same route as a stopped one.
        recorder.onInterrupted = { url in sync.send(url) }
        _sync = State(initialValue: sync)
        _recorder = State(initialValue: recorder)
    }

    var body: some Scene {
        WindowGroup {
            RecordView(recorder: recorder, sync: sync)
                .onOpenURL { url in
                    // The complication's tap arrives here, on the face's own terms.
                    if url.host == "record" { WatchRecordingRequest.raise() }
                }
        }
    }
}
