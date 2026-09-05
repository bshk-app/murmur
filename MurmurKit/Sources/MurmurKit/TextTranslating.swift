import Foundation

/// What both translation engines have in common, which is very little on
/// purpose.
///
/// The two are not interchangeable and the protocol does not pretend they are:
/// it exists so `TranslationService` can hold either in one cache slot, not so
/// callers can pick one at random. Which engine runs is decided by
/// `TranslationTier`, from the phase of the work, never from availability
/// alone.
public protocol TextTranslating: AnyObject {
    var pair: LanguagePair { get }
    func translate(_ text: String) throws -> String
}

/// Which engine a piece of work is asking for.
///
/// This is a statement about the *work*, not about the machine: `.fast` means
/// "this text will be replaced within a second", `.best` means "this is what
/// the user keeps". Latency is the consequence, not the criterion.
public enum TranslationTier: Sendable, Hashable {
    /// bergamot student, ~12 ms. Captions and the live draft.
    case fast
    /// opus-mt tc-big under CTranslate2 int8, ~378 ms. The final paste.
    ///
    /// Falls back to `.fast` per leg when no quality model is installed for
    /// that direction, which is the normal case: quality models are 253 MB
    /// each and downloaded on demand, so most directions will never have one.
    case best
}

extension LanguagePair {
    /// Directory holding the converted CTranslate2 model, kept distinct from
    /// `modelDirectoryName` so both engines can be installed for one pair.
    public var qualityModelDirectoryName: String { "ct2-\(source)\(target)" }
}
