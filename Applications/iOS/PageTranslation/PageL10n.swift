import Foundation

enum PageL10n {
    static func text(_ key: String) -> String { NSLocalizedString(key, tableName: "PageTranslation", bundle: .main, comment: "") }
    static func format(_ key: String, _ args: CVarArg...) -> String { String(format: text(key), locale: Locale.current, arguments: args) }
}
