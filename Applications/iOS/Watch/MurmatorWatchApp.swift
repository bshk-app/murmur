import SwiftUI

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
        WindowGroup { RecordView(recorder: recorder, sync: sync) }
    }
}
