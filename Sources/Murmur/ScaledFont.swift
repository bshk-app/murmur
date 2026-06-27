import SwiftUI

/// A fixed design size that still scales with the user's text-size setting.
/// `Text(...).murFont(14.5, weight: .medium)` looks identical to
/// `.system(size: 14.5)` at the default size but grows with Larger Text.
private struct MurScaledFont: ViewModifier {
    @ScaledMetric var size: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    init(_ size: CGFloat, weight: Font.Weight, design: Font.Design) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: .body)
        self.weight = weight; self.design = design
    }
    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: design))
    }
}

extension View {
    func murFont(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(MurScaledFont(size, weight: weight, design: design))
    }
}
