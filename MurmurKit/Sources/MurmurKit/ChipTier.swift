import Foundation

/// Apple Silicon performance tier, as far as the CPU brand string reveals it.
///
/// The thing that actually decides whether the hybrid pipeline keeps up is memory
/// bandwidth — a 4 B model streams its weights every step — and no public API
/// reports it. The tier name is the closest proxy macOS will tell us: base parts
/// sit near 70–120 GB/s, Pro near 200–270, Max 400+.
public enum ChipTier: String, Sendable {
    case base, pro, max, ultra, unknown

    public static func parse(_ brandString: String) -> ChipTier {
        let s = brandString.lowercased()
        guard s.contains("apple") else { return .unknown }
        if s.contains("ultra") { return .ultra }
        if s.contains("max") { return .max }
        if s.contains("pro") { return .pro }
        return .base
    }

    /// The dictation mode this machine should start on. Anything we cannot place
    /// gets the mode that runs everywhere, not the one that asks the most.
    public var recommendedMode: DictationMode {
        switch self {
        case .pro, .max, .ultra: return .hybrid
        case .base, .unknown:    return .fast
        }
    }

    /// This machine's tier, from `machdep.cpu.brand_string`. The untestable edge:
    /// everything above works on a plain string so it can be exercised offline.
    public static var current: ChipTier = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return .unknown }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        return parse(String(cString: buf))
    }()
}
