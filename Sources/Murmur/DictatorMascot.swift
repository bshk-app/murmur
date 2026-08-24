import Foundation
import SwiftUI

enum DictatorMascotMood: Equatable {
    case idle
    case listening
    case transcribing
    case success
    case error
}

/// Layered mascot shared by the HUD, menu popover and onboarding. Facial layers
/// move independently while the approved painted character stays pixel-identical.
struct DictatorMascot: View {
    let mood: DictatorMascotMood
    var size: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animationStart = Date.now

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let elapsed = reduceMotion ? 0 : max(0, context.date.timeIntervalSince(animationStart))
            let pose = DictatorMascotPose(mood: mood, elapsed: elapsed)

            ZStack {
                layer("dictator_face")
                layer("dictator_brow_left", angle: pose.leftBrowAngle,
                      offset: pose.leftBrowOffset, anchor: UnitPoint(x: 0.42, y: 0.57))
                layer("dictator_brow_right", angle: pose.rightBrowAngle,
                      offset: pose.rightBrowOffset, anchor: UnitPoint(x: 0.58, y: 0.57))
                layer("dictator_moustache_left", angle: pose.leftMoustacheAngle,
                      offset: pose.leftMoustacheOffset, anchor: UnitPoint(x: 0.49, y: 0.75))
                layer("dictator_moustache_right", angle: pose.rightMoustacheAngle,
                      offset: pose.rightMoustacheOffset, anchor: UnitPoint(x: 0.51, y: 0.75))
            }
            .frame(width: size, height: size)
            .offset(pose.faceOffset)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .onChange(of: mood) { _, _ in animationStart = .now }
    }

    private func layer(_ name: String, angle: Double = 0, offset: CGSize = .zero,
                       anchor: UnitPoint = .center) -> some View {
        Image(name)
            .renderingMode(.original)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .rotationEffect(.degrees(angle), anchor: anchor)
            .offset(offset)
    }
}

private struct DictatorMascotPose {
    var faceOffset = CGSize.zero
    var leftBrowAngle = 0.0
    var rightBrowAngle = 0.0
    var leftBrowOffset = CGSize.zero
    var rightBrowOffset = CGSize.zero
    var leftMoustacheAngle = 0.0
    var rightMoustacheAngle = 0.0
    var leftMoustacheOffset = CGSize.zero
    var rightMoustacheOffset = CGSize.zero

    init(mood: DictatorMascotMood, elapsed: TimeInterval) {
        switch mood {
        case .idle:
            faceOffset.height = -0.6 * sin(elapsed * .pi * 2 / 2.4)

        case .listening:
            let wave = (sin(elapsed * .pi * 2 * 1.55) + 1) / 2
            leftBrowAngle = -6 * wave
            rightBrowAngle = 6 * wave
            leftBrowOffset.height = -1.65 * wave
            rightBrowOffset.height = -1.65 * wave
            leftMoustacheAngle = -6 * wave
            rightMoustacheAngle = 6 * wave
            leftMoustacheOffset.height = -0.8 * wave
            rightMoustacheOffset.height = -0.8 * wave

        case .transcribing:
            let wave = sin(elapsed * .pi * 2 * 1.05)
            leftBrowAngle = -6 * wave
            rightBrowAngle = 6 * wave
            leftBrowOffset.height = -1.1 - 0.7 * wave
            rightBrowOffset.height = -1.1 + 0.7 * wave
            leftMoustacheAngle = -5 * wave
            rightMoustacheAngle = 5 * wave
            leftMoustacheOffset.width = -0.65 * wave
            rightMoustacheOffset.width = 0.65 * wave

        case .success:
            let progress = min(1, elapsed / 0.72)
            let pop = sin(min(1, progress * 1.35) * .pi)
            faceOffset.height = 1.6 * sin(progress * .pi * 2 * 1.8) * exp(-3.6 * progress)
            leftBrowAngle = -7 * pop
            rightBrowAngle = 7 * pop
            leftBrowOffset.height = -2 * pop
            rightBrowOffset.height = -2 * pop
            leftMoustacheAngle = -10 * pop
            rightMoustacheAngle = 10 * pop
            leftMoustacheOffset.height = -0.7 * pop
            rightMoustacheOffset.height = -0.7 * pop

        case .error:
            let envelope = max(0, 1 - elapsed / 0.5)
            faceOffset.width = 1.5 * sin(elapsed * .pi * 2 * 9) * envelope
            leftBrowAngle = 10
            rightBrowAngle = 5
            leftBrowOffset.height = -1.3
            rightBrowOffset.height = 0.7
            leftMoustacheAngle = 8
            rightMoustacheAngle = -8
            leftMoustacheOffset.height = 1.2
            rightMoustacheOffset.height = 1.2
        }
    }
}
