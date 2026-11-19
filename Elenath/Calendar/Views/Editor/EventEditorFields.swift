import AppKit
import ElenathCore
import SwiftUI

/// The editor's form rows, with right-aligned labels in `TextSecondary`: Date, All-day, Time (or Ends for
/// all-day events), Subject, Location, Alert, Repeat and Notes.
struct EventEditorFields: View {
    @Binding var draft: EventEditorDraft
    /// Where the notes are kept when they may not be read here ("" when that space can't be named); nil
    /// shows the notes.
    var notesKeptIn: String? = nil

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                EditorRowLabel(title: "Date")
                    .gridColumnAlignment(.trailing)
                DatePicker("Date", selection: $draft.startDay, displayedComponents: .date)
                    .datePickerStyle(.field)
                    .labelsHidden()
                    .fixedSize()
            }
            GridRow {
                EditorRowLabel(title: "All-day")
                Toggle("All-day", isOn: $draft.allDay)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(Color.accentColor)
                    .labelsHidden()
            }
            if draft.isAllDay {
                GridRow {
                    EditorRowLabel(title: "Ends")
                    EditorEndDayField(draft: $draft)
                }
            } else {
                GridRow {
                    EditorRowLabel(title: "Time")
                    EditorTimeFields(draft: $draft)
                }
            }
            GridRow {
                EditorRowLabel(title: "Subject")
                EditorSubjectPicker(subjectID: $draft.subjectID)
            }
            GridRow {
                EditorRowLabel(title: "Location")
                EditorTextField(title: "Location", prompt: "Add Location", text: $draft.location)
            }
            GridRow {
                EditorRowLabel(title: "Alert")
                EditorAlertPicker(alert: $draft.alert)
            }
            GridRow {
                EditorRowLabel(title: "Repeat")
                EditorRepeatPicker(frequency: $draft.frequency)
            }
            GridRow(alignment: .top) {
                EditorRowLabel(title: "Notes")
                    .padding(.top, 4)
                if let notesKeptIn {
                    Group {
                        if notesKeptIn.isEmpty {
                            Text("These notes aren't shown here.")
                        } else {
                            Text("Notes are kept in \(notesKeptIn).")
                        }
                    }
                    .font(Typography.secondary)
                    .foregroundStyle(Color.textTertiary)
                    .padding(.top, 4)
                } else {
                    EditorNotesField(notes: $draft.notes)
                }
            }
        }
    }
}

private struct EditorRowLabel: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(Typography.body)
            .foregroundStyle(Color.textSecondary)
            .lineLimit(1)
            .accessibilityHidden(true)
    }
}

/// "10:00 to 11:00" and a duration hint ("1 hr") in `TextTertiary`.
private struct EditorTimeFields: View {
    @Binding var draft: EventEditorDraft

    var body: some View {
        HStack(spacing: 6) {
            DatePicker("Start Time", selection: $draft.startTime, displayedComponents: .hourAndMinute)
                .datePickerStyle(.field)
                .labelsHidden()
                .fixedSize()
            Text("to", comment: "Between an event's start and end time")
                .font(Typography.body)
                .foregroundStyle(Color.textSecondary)
                .accessibilityHidden(true)
            DatePicker("End Time", selection: $draft.endTime, displayedComponents: .hourAndMinute)
                .datePickerStyle(.field)
                .labelsHidden()
                .fixedSize()
            Text(EditorDuration.text(seconds: draft.duration))
                .font(Typography.secondary)
                .monospacedDigit()
                .foregroundStyle(Color.textTertiary)
                .lineLimit(1)
                .accessibilityLabel(Text("Duration \(EditorDuration.text(seconds: draft.duration))"))
        }
    }
}

/// The last day of an all-day event, never before the first, and how many days that makes.
private struct EditorEndDayField: View {
    @Binding var draft: EventEditorDraft

    var body: some View {
        HStack(spacing: 8) {
            DatePicker("Ends", selection: $draft.endDay, in: draft.startDay..., displayedComponents: .date)
                .datePickerStyle(.field)
                .labelsHidden()
                .fixedSize()
            if draft.dayCount > 1 {
                Text(EditorDuration.text(days: draft.dayCount))
                    .font(Typography.secondary)
                    .monospacedDigit()
                    .foregroundStyle(Color.textTertiary)
                    .lineLimit(1)
            }
        }
    }
}

/// "No Subject", then every subject with a dot in its color.
private struct EditorSubjectPicker: View {
    @Environment(CalendarModel.self) private var model
    @Binding var subjectID: UUID?

    var body: some View {
        Picker("Subject", selection: $subjectID) {
            Text("No Subject")
                .tag(UUID?.none)
            if !model.library.subjects.isEmpty {
                Divider()
            }
            ForEach(model.library.subjects) { subject in
                Label {
                    Text(subject.name)
                } icon: {
                    Image(nsImage: SubjectSwatch.image(for: subject))
                }
                .tag(UUID?.some(subject.id))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }
}

/// At time of event · 10 minutes before · 1 hour before · 1 day before · divider · None.
private struct EditorAlertPicker: View {
    @Binding var alert: AlertOffset?

    var body: some View {
        Picker("Alert", selection: $alert) {
            ForEach(AlertChoices.offered(including: alert), id: \.self) { offset in
                Text(EventFormatting.alert(offset))
                    .tag(AlertOffset?.some(offset))
            }
            Divider()
            Text(EventFormatting.alert(nil))
                .tag(AlertOffset?.none)
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }
}

private struct EditorRepeatPicker: View {
    @Binding var frequency: RecurrenceRule.Frequency?

    var body: some View {
        Picker("Repeat", selection: $frequency) {
            Text("Never")
                .tag(RecurrenceRule.Frequency?.none)
            Divider()
            Text("Every Day")
                .tag(RecurrenceRule.Frequency?.some(.daily))
            Text("Every Week")
                .tag(RecurrenceRule.Frequency?.some(.weekly))
            Text("Every Month")
                .tag(RecurrenceRule.Frequency?.some(.monthly))
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }
}

/// A single-line field on `ControlFill`.
private struct EditorTextField: View {
    let title: LocalizedStringKey
    let prompt: LocalizedStringKey
    @Binding var text: String

    var body: some View {
        TextField(title, text: $text, prompt: Text(prompt))
            .textFieldStyle(.plain)
            .font(Typography.body)
            .foregroundStyle(Color.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous)
                    .fill(Color.controlFill)
            }
    }
}

/// About three lines of notes on `ControlFill`, with an "Add Notes" placeholder.
private struct EditorNotesField: View {
    @Binding var notes: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $notes)
                .font(Typography.body)
                .foregroundStyle(Color.textPrimary)
                .scrollContentBackground(.hidden)
                .accessibilityLabel(Text("Notes"))
            if notes.isEmpty {
                Text("Add Notes")
                    .font(Typography.body)
                    .foregroundStyle(Color.textTertiary)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(height: 52)
        .padding(.horizontal, 3)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous)
                .fill(Color.controlFill)
        }
    }
}

/// The duration hints next to the times: "1 hr", "1 hr, 30 min", "3 days", in the user's language.
enum EditorDuration {
    static func text(seconds: TimeInterval) -> String {
        let minutes = (max(0, seconds) / 60).rounded()
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .short
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = .dropAll
        if minutes == 0 {
            formatter.allowedUnits = [.minute]
            formatter.zeroFormattingBehavior = .default
        }
        return formatter.string(from: minutes * 60) ?? ""
    }

    static func text(days: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .short
        formatter.allowedUnits = [.day]
        var components = DateComponents()
        components.day = days
        return formatter.string(from: components) ?? ""
    }
}

/// The alert choices menus offer.
enum AlertChoices {
    /// The presets (at time of event, 10 minutes, 1 hour, 1 day), plus `current` when it is some other
    /// offset (from a hand-edited events.json), so the menu can show it.
    static func offered(including current: AlertOffset?) -> [AlertOffset] {
        var offsets = AlertOffset.presets
        if let current, !offsets.contains(current) {
            offsets.append(current)
            offsets.sort()
        }
        return offsets
    }
}

/// Small filled circles in a subject's color, as images for menu items: menus draw SwiftUI symbols as
/// templates and drop their color.
enum SubjectSwatch {
    static func image(for subject: Subject?, diameter: CGFloat = 10) -> NSImage {
        let choice = subject?.color
        let size = NSSize(width: diameter, height: diameter)
        let image = NSImage(size: size, flipped: false) { rect in
            SubjectSwatch.color(for: choice).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    /// The subject color as a dynamic `NSColor`, resolved for the appearance it is drawn in.
    static func color(for choice: SubjectColor?) -> NSColor {
        switch choice {
        case .palette(let palette)?:
            return NSColor(resource: SubjectStyle.resource(for: palette))
        case .custom(let red, let green, let blue)?:
            return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        case nil:
            return NSColor(resource: .textSecondary)
        }
    }
}
