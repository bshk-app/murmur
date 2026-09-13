import Foundation
import SwiftUI

struct MurmurMascot: View {
    var warming = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animation = MurmurPetAnimation.idle
    @State private var animationStart = Date.now
    @State private var nextReactionIndex = 0
    @State private var playbackID = 0
    @State private var pulseExpanded = false

    private static let tapReactions: [MurmurPetAnimation] = [
        .waving,
        .jumping,
        .running,
        .review,
    ]

    var body: some View {
        Button(action: playNextReaction) {
            ZStack {
                Circle()
                    .fill(MurmurPalette.accent.opacity(warming ? 0 : 0.14))
                    .frame(width: warming ? 70 : 132, height: warming ? 70 : 132)

                if !warming {
                    Circle()
                        .stroke(
                            MurmurPalette.accent.opacity(reduceMotion ? 0.2 : pulseExpanded ? 0 : 0.5),
                            lineWidth: 1.5
                        )
                        .frame(width: 132, height: 132)
                        .scaleEffect(reduceMotion ? 1 : pulseExpanded ? 1.4 : 1)
                        .onAppear(perform: startPulse)
                        .onChange(of: reduceMotion, updatePulse)
                }

                if warming {
                    Circle()
                        .stroke(MurmurPalette.accent.opacity(0.25), lineWidth: 2)
                        .frame(width: 70, height: 70)
                }

                petAnimation
            }
            .frame(width: 132, height: 132)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .disabled(warming)
        .frame(maxWidth: .infinity)
        .sensoryFeedback(.impact(weight: .light), trigger: playbackID)
        .accessibilityLabel("Murmator mascot")
        .accessibilityHint(warming ? Text("") : Text("Tap to see another animation"))
        .accessibilityIdentifier("mascot")
        .task(id: playbackID) {
            await returnToIdleAfterReaction()
        }
    }

    private var petAnimation: some View {
        TimelineView(
            .animation(
                minimumInterval: animation.minimumFrameDuration,
                paused: reduceMotion || warming
            )
        ) { context in
            MurmurPetAtlasFrame(
                row: animation.row,
                column: animation.frame(
                    at: context.date.timeIntervalSince(animationStart),
                    reduceMotion: reduceMotion
                ),
                height: warming ? 48 : 112
            )
        }
    }

    private func playNextReaction() {
        guard !warming else { return }

        if !reduceMotion {
            animation = Self.tapReactions[nextReactionIndex]
            animationStart = .now
        }
        nextReactionIndex = (nextReactionIndex + 1) % Self.tapReactions.count
        playbackID += 1
    }

    private func returnToIdleAfterReaction() async {
        guard playbackID > 0, !reduceMotion else { return }
        let scheduledAnimation = animation

        do {
            try await Task.sleep(for: .seconds(scheduledAnimation.totalDuration))
            try Task.checkCancellation()
        } catch {
            return
        }

        guard animation == scheduledAnimation else { return }
        animation = .idle
        animationStart = .now
    }

    private func startPulse() {
        guard !reduceMotion else { return }
        withAnimation(.easeOut(duration: 2.4).repeatForever(autoreverses: false)) {
            pulseExpanded = true
        }
    }

    private func updatePulse() {
        if reduceMotion {
            animation = .idle
            animationStart = .now
            withAnimation(nil) { pulseExpanded = false }
        } else {
            startPulse()
        }
    }
}

private enum MurmurPetAnimation: Equatable {
    case idle
    case waving
    case jumping
    case running
    case review

    private static let idleDurations: [TimeInterval] = [0.28, 0.11, 0.11, 0.14, 0.14, 0.32]
    private static let wavingDurations: [TimeInterval] = [0.14, 0.14, 0.14, 0.28]
    private static let jumpingDurations: [TimeInterval] = [0.14, 0.14, 0.14, 0.14, 0.28]
    private static let runningDurations: [TimeInterval] = [0.12, 0.12, 0.12, 0.12, 0.12, 0.22]
    private static let reviewDurations: [TimeInterval] = [0.15, 0.15, 0.15, 0.15, 0.15, 0.28]

    var row: Int {
        switch self {
        case .idle: 0
        case .waving: 3
        case .jumping: 4
        case .running: 7
        case .review: 8
        }
    }

    var repeats: Bool { self == .idle }

    var durations: [TimeInterval] {
        switch self {
        case .idle: Self.idleDurations
        case .waving: Self.wavingDurations
        case .jumping: Self.jumpingDurations
        case .running: Self.runningDurations
        case .review: Self.reviewDurations
        }
    }

    var minimumFrameDuration: TimeInterval {
        durations.min() ?? 0.12
    }

    var totalDuration: TimeInterval {
        durations.reduce(0, +)
    }

    func frame(at elapsed: TimeInterval, reduceMotion: Bool) -> Int {
        guard !reduceMotion else { return 0 }

        let positiveElapsed = max(0, elapsed)
        let playbackTime = repeats
            ? positiveElapsed.truncatingRemainder(dividingBy: totalDuration)
            : min(positiveElapsed, totalDuration)
        var frameEnd: TimeInterval = 0

        for (index, duration) in durations.enumerated() {
            frameEnd += duration
            if playbackTime < frameEnd { return index }
        }
        return durations.count - 1
    }
}

private struct MurmurPetAtlasFrame: View {
    let row: Int
    let column: Int
    let height: CGFloat

    private var width: CGFloat { height * 192 / 208 }

    var body: some View {
        Image("MurmurPetAtlas")
            .renderingMode(.original)
            .resizable()
            .interpolation(.high)
            .frame(width: width * 8, height: height * 11, alignment: .topLeading)
            .offset(x: -CGFloat(column) * width, y: -CGFloat(row) * height)
            .frame(width: width, height: height, alignment: .topLeading)
            .clipped()
            .transaction { $0.animation = nil }
            .accessibilityHidden(true)
    }
}
