import SwiftUI

/// A section header with the accent-coloured rule used throughout the details sidebar, that also
/// collapses its content.
struct CollapsibleSection<Content: View>: View {
    let title: String
    @State private var isExpanded: Bool
    private let content: () -> Content

    init(title: String, initiallyExpanded: Bool = true, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self._isExpanded = State(initialValue: initiallyExpanded)
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(title)
                    VStack {
                        Divider()
                            .frame(height: 1)
                            .overlay(Color.accentColor)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
