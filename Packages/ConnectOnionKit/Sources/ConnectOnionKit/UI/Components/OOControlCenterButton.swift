import SwiftUI

/// Control Center button
/// shows and hides it
public struct OOControlCenterButton: View {
    private let isOpen: Bool
    private let action: () -> Void

    public init(isOpen: Bool, action: @escaping () -> Void) {
        self.isOpen = isOpen
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Label("Control Center", systemImage: "square.grid.2x2")
                .labelStyle(.titleAndIcon)
        }
        .help(Self.accessibilityLabel(isOpen: isOpen))
        .accessibilityLabel(Self.accessibilityLabel(isOpen: isOpen))
    }

    static func accessibilityLabel(isOpen: Bool) -> String {
        isOpen ? "Collapse Control Center" : "Open Control Center"
    }
}

#Preview("Control Center button") {
    HStack {
        OOControlCenterButton(isOpen: true) {}
        OOControlCenterButton(isOpen: false) {}
    }
    .preferredColorScheme(.dark)
    .padding()
}
