import Foundation

enum L10n {
    static func text(_ key: String) -> String { NSLocalizedString(key, bundle: .main, comment: "") }
    static func format(_ key: String, _ value: String) -> String {
        String(format: text(key), locale: Locale.current, value)
    }
    static func format(_ key: String, _ first: Int, _ second: Int) -> String {
        String(format: text(key), locale: Locale.current, first, second)
    }
}
