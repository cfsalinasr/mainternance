import SwiftUI

/// Opaque surface for data cards; glass is reserved for chrome (sidebar, banner, popover).
struct SolidCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

extension View {
    func solidCard() -> some View {
        modifier(SolidCard())
    }
}
