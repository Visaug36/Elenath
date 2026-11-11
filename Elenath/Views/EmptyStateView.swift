import SwiftUI

/// Illustration, New York headline and an SF Pro secondary line: the layout of every empty state.
struct EmptyStateView: View {
    let illustration: ImageResource
    let title: LocalizedStringKey
    let message: LocalizedStringKey

    var body: some View {
        VStack(spacing: 6) {
            Image(illustration)
                .accessibilityHidden(true)
                .padding(.bottom, 10)
            Text(title)
                .font(Typography.emptyHeadline)
                .foregroundStyle(Color.textPrimary)
            Text(message)
                .font(Typography.secondary)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    EmptyStateView(
        illustration: .emptySky,
        title: "Nothing here yet.",
        message: "This early build only shows Elenath’s window. Notes arrive in version 0.1."
    )
    .frame(width: 360, height: 280)
    .starryBackground(.backgroundWindow)
}
