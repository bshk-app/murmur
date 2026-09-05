import XCTest
@testable import Murmur
@testable import MurmurKit

/// A live screenshot showed a caption's translation vanish: closing text
/// missing from the HUD's second line entirely, with no error a user could
/// see. `StartupTests` proves the write-ordering half of that bug (an older
/// snapshot's pass overwriting a newer one's HUD write). This proves the
/// other half: `CaptionTranslator`'s own cache must not be read before a
/// pending `reset()` - spawned when a talk or its target language changes -
/// has actually finished. A new caption session gets a brand-new
/// `CaptionEngine` (`TwoTierEngine.makeCaptionEngine`), whose segment ids
/// restart at 1, so back-to-back sessions collide on id *and*, for a
/// repeated or common opening phrase, on text too. Reading `done[1]` before
/// a reset that should have cleared it returns the previous session's
/// translation, in the previous session's language, with nothing downstream
/// able to tell it apart from a correct cache hit.
@MainActor
final class CaptionTranslationOrderingTests: XCTestCase {
    private actor OrderLog {
        private(set) var events: [String] = []
        func record(_ e: String) { events.append(e) }
    }

    /// Held closed for as long as the test wants, so "a reset is pending"
    /// can be simulated deterministically instead of racing the real
    /// (near-instant, no-op-bodied) `CaptionTranslator.reset()`.
    private actor Gate {
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if open { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() {
            open = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }

    private struct LoggingFakeTranslator: PhraseTranslating {
        let log: OrderLog
        func translateOrEmpty(_ text: String, from source: String, to target: String) async -> String {
            await log.record("translated:\(text)->\(target)")
            return "[\(target)] \(text)"
        }
    }

    func testTranslateCaptionsWaitsForAPendingResetBeforeReadingTheCache() async {
        let controller = DictationController()
        let log = OrderLog()
        controller.captionTranslation = CaptionTranslator(service: LoggingFakeTranslator(log: log))

        let savedTarget = UserDefaults.standard.string(forKey: TranslationSetting.key)
        defer {
            if let savedTarget {
                UserDefaults.standard.set(savedTarget, forKey: TranslationSetting.key)
            } else {
                UserDefaults.standard.removeObject(forKey: TranslationSetting.key)
            }
        }
        UserDefaults.standard.set("en", forKey: TranslationSetting.key)
        controller.captionSource = "ru"
        controller.captionTarget = "en"

        // A reset is "in flight" - as it would be right after a talk or its
        // target starts, before the fire-and-forget clear has necessarily
        // reached the actor - and stays that way until the test releases it.
        let gate = Gate()
        controller.captionTranslationReset = Task {
            await gate.wait()
            await log.record("reset-released")
        }

        let snapshot = CaptionSnapshot(
            revision: 1,
            confirmed: [CaptionSegment(id: 1, startSample: 0, endSample: 100,
                                        text: "Привет", state: .confirmed)],
            provisional: "")
        controller.translateCaptions(snapshot)

        // A fixed wall-clock sleep here would only be a *probably* reliable
        // head start: on a slow or loaded machine, a mutation that skips
        // `await pendingReset?.value` could still lose the race and log
        // after the gate opens, passing the test for the wrong reason. Ticks
        // of the cooperative scheduler are what actually matter here, not
        // elapsed time: under the mutation there is no further suspension
        // between the task starting and reaching `translateOrEmpty` (the
        // cache-check loop inside `CaptionTranslator.translation` runs
        // synchronously up to that call), so handing the scheduler many
        // chances to run anything runnable guarantees that call has already
        // happened, on any machine, regardless of how fast or slow it is.
        for _ in 0 ..< 1_000 { await Task.yield() }
        await gate.release()
        await controller.captionTranslateTask?.value

        let events = await log.events
        XCTAssertEqual(events, ["reset-released", "translated:Привет->en"],
                       "the cache must not be read until the pending reset actually finished")
    }
}
