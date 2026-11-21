import ElenathCore
import SwiftUI

/// The sidebar's "Subjects" list: a rounded checkbox in each subject's color that shows or hides its
/// events. With no subjects yet it points to Settings, where they're made.
struct SidebarSubjectsSection: View {
    @Environment(CalendarModel.self) private var model

    var body: some View {
        let subjects = model.library.subjects
        VStack(alignment: .leading, spacing: 2) {
            CalendarSidebarSectionLabel(title: "Subjects")
            if subjects.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add subjects in Settings")
                        .font(Typography.secondary)
                        .foregroundStyle(Color.textTertiary)
                    SettingsLink {
                        Text("Open Settings…")
                            .font(Typography.secondary)
                            .foregroundStyle(Color.accentText)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
            } else {
                ForEach(subjects) { subject in
                    SidebarSubjectRow(subject: subject)
                }
            }
        }
    }
}

private struct SidebarSubjectRow: View {
    @Environment(CalendarModel.self) private var model
    let subject: Subject
    @State private var isHovered = false

    var body: some View {
        let isVisible = model.isVisible(subject.id)
        Button {
            model.setVisible(!isVisible, subjectID: subject.id)
        } label: {
            HStack(spacing: 9) {
                SidebarSubjectCheckbox(color: SubjectStyle.color(for: subject), isOn: isVisible)
                Text(subject.name)
                    .font(Typography.body)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(Metrics.Padding.sidebarRow)
            .background {
                RoundedRectangle(cornerRadius: Metrics.Radius.listRow, style: .continuous)
                    .fill(isHovered ? Color.controlFill : Color.clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityLabel(subject.name)
        .accessibilityValue(isVisible ? Text("Shown") : Text("Hidden"))
        .accessibilityHint(Text("Shows or hides this subject's events"))
        .accessibilityAddTraits(traits(isVisible: isVisible))
    }

    private func traits(isVisible: Bool) -> AccessibilityTraits {
        isVisible ? [.isSelected] : []
    }
}

/// A rounded checkbox: filled with the subject color and a dark checkmark when on, an outline when off.
private struct SidebarSubjectCheckbox: View {
    let color: Color
    let isOn: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(isOn ? color : Color.clear)
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(color, lineWidth: 1.5)
            }
            .overlay {
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(Color.textOnAccent)
                }
            }
            .frame(width: 14, height: 14)
            .accessibilityHidden(true)
    }
}
