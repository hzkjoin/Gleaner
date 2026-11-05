import SwiftUI

/// A vertical scroll view that is exactly as tall as its content, up to `maxHeight`.
///
/// A plain `ScrollView` has no ideal height, so inside a panel that sizes itself to its content
/// it collapses to almost nothing. This measures the content instead.
struct AutoSizingScrollView<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: Content

    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            content.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .frame(height: min(max(contentHeight, 1), maxHeight))
    }
}
