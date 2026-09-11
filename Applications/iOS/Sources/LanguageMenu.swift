import SwiftUI

/// Installed directions stay at the top; the complete catalog is one submenu away.
struct LanguageMenu: View {
    @Binding var selection: String
    let codes: [String]
    let preferred: [String]
    var identifier: String
    var body: some View {
        Menu {
            LanguageMenuChoices(selection: selection, codes: codes, preferred: preferred) { selection = $0 }
        } label: {
            HStack(spacing: 6) {
                Text(menuLanguageName(selection))
                Image(systemName: "chevron.down").font(.caption).accessibilityHidden(true)
            }.frame(minHeight: 44).contentShape(Rectangle())
        }.accessibilityIdentifier(identifier).accessibilityValue(menuLanguageName(selection))
    }
}

struct LanguageMenuChoices: View {
    var selection: String?
    let codes: [String]
    let preferred: [String]
    let select: (String) -> Void
    private var promoted: [String] { sorted(codes.filter { preferred.contains($0) || $0 == selection }) }
    private var other: [String] { sorted(codes.filter { !preferred.contains($0) && $0 != selection }) }
    var body: some View {
        if !promoted.isEmpty { Section("Your languages") { choices(promoted) } }
        if !other.isEmpty { Menu("Other languages…") { choices(other) } }
    }
    private func sorted(_ values: [String]) -> [String] {
        values.sorted { menuLanguageName($0).localizedStandardCompare(menuLanguageName($1)) == .orderedAscending }
    }
    private func choices(_ values: [String]) -> some View {
        ForEach(values, id: \.self) { code in
            Button { select(code) } label: {
                HStack {
                    Text(menuLanguageName(code))
                    if code == selection { Image(systemName: "checkmark") }
                    else if !preferred.contains(code) { Image(systemName: "arrow.down.circle") }
                }
            }
        }
    }
}

private func menuLanguageName(_ code: String) -> String {
    Locale.current.localizedString(forLanguageCode: code)?.localizedCapitalized ?? code.uppercased()
}
