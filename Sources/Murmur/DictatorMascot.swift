import Foundation
import SwiftUI

enum DictatorMascotMood: Equatable {
    case idle, listening, transcribing, success, error

    var animation: (row: Int, count: Int, interval: TimeInterval, repeats: Bool) {
        switch self {
        case .idle: return (0, 6, 0.18, true)
        case .listening: return (6, 6, 0.17, true)
        case .transcribing: return (7, 6, 0.14, true)
        case .success: return (4, 5, 0.17, false)
        // Hold the disappointed pose instead of returning to neutral.
        case .error: return (5, 5, 0.16, false)
        }
    }

    func frame(at elapsed: TimeInterval, reduceMotion: Bool) -> Int {
        if reduceMotion { return self == .error ? 4 : 0 }
        let position = max(0, elapsed) / animation.interval
        if animation.repeats {
            return Int(position.truncatingRemainder(dividingBy: Double(animation.count)))
        }
        return Int(min(position, Double(animation.count - 1)))
    }
}

/// Plays the approved atlas in the HUD, menu, and onboarding.
struct DictatorMascot: View {
    let mood: DictatorMascotMood
    var size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Playback(mood: mood, size: size, reduceMotion: reduceMotion)
            .id(mood)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private struct Playback: View {
        let mood: DictatorMascotMood
        let size: CGFloat
        let reduceMotion: Bool
        @State private var start = Date.now

        var body: some View {
            let animation = mood.animation
            TimelineView(.animation(minimumInterval: animation.interval, paused: reduceMotion)) { context in
                let column = mood.frame(at: context.date.timeIntervalSince(start), reduceMotion: reduceMotion)
                let width = size * 192 / 208
                Image("murmur_pet")
                    .renderingMode(.original)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: width * 8, height: size * 11)
                    .offset(x: -CGFloat(column) * width, y: -CGFloat(animation.row) * size)
                    .frame(width: width, height: size, alignment: .topLeading)
                    .clipped()
            }
        }
    }
}
