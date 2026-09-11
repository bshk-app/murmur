import SwiftUI

/// Native List rows provide swipe arbitration, dismissal and accessibility on iOS 18+.
struct ActionList<Content: View>: View {
    var horizontalPadding: CGFloat = 20
    var spacing: CGFloat = 10
    @ViewBuilder var content: Content

    var body: some View {
        List {
            content
                .listRowInsets(EdgeInsets(top: 0, leading: horizontalPadding, bottom: 0, trailing: horizontalPadding))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .listRowSpacing(spacing)
        .scrollContentBackground(.hidden)
        .contentMargins(.vertical, 12, for: .scrollContent)
        .environment(\.defaultMinListRowHeight, 0)
    }
}

struct RowAction: Identifiable {
    let id: String
    let title: String
    let symbol: String
    var edge: HorizontalEdge? = .trailing
    var destructive = false
    var enabled = true
    let perform: () -> Void
}

private struct RowActions: ViewModifier {
    let actions: [RowAction]
    func body(content: Content) -> some View {
        content
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 16))
            .contextMenu {
                ForEach(actions) { action in
                    Button(role: action.destructive ? .destructive : nil) { run(action) } label: {
                        Label(LocalizedStringKey(action.title), systemImage: action.symbol)
                    }.disabled(!action.enabled).accessibilityIdentifier("menu-" + action.id)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) { buttons(on: .trailing) }
            .swipeActions(edge: .leading, allowsFullSwipe: false) { buttons(on: .leading) }
            .accessibilityActions {
                ForEach(actions.filter(\.enabled)) { action in
                    Button(LocalizedStringKey(action.title)) { run(action) }
                }
            }
    }
    private func buttons(on edge: HorizontalEdge) -> some View {
        ForEach(actions.filter { $0.edge == edge }) { action in
            // A destructive swipe role optimistically removes a List row before a
            // confirmation. Keep it visible until the existing handler succeeds.
            Button { run(action) } label: {
                Label(LocalizedStringKey(action.title), systemImage: action.symbol)
            }
            .tint(action.destructive ? .red : edge == .leading ? .blue : .orange)
            .disabled(!action.enabled)
            .accessibilityIdentifier("swipe-" + action.id)
        }
    }
    private func run(_ action: RowAction) { if action.enabled { action.perform() } }
}

extension View {
    func rowActions(_ actions: [RowAction]) -> some View { modifier(RowActions(actions: actions)) }
}
