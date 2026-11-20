import SwiftUI

/// shows a component in light and dark side by side, for previews
struct OOPreviewPair<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            content.padding().background(OOColor.paper).environment(\.colorScheme, .light)
            content.padding().background(OOColor.paper).environment(\.colorScheme, .dark)
        }
    }
}
