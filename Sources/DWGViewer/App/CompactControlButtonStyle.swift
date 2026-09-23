import SwiftUI

/// Keep small glyphs compact while giving the whole button a usable target.
struct CompactControlButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minWidth: 28, minHeight: 28)
            .contentShape(Rectangle())
            .background(configuration.isPressed ? Color.primary.opacity(0.08) : .clear,
                        in: RoundedRectangle(cornerRadius: 4))
            .opacity(isEnabled ? 1 : 0.4)
    }
}
