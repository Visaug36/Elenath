import ElenathCore
import SwiftUI

/// A small filled circle in the subject's color. Decorative: the subject or event it sits next to
/// carries the VoiceOver label.
struct SubjectDot: View {
    let subject: Subject?
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(SubjectStyle.color(for: subject))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
