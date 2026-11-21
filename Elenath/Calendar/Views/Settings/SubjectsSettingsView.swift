import AppKit
import ElenathCore
import SwiftUI

/// Subjects: one card per subject with its color, name, palette, Quick Add keywords and home (the space
/// and folder its notes go to, which its events' sealing follows), and "Add Subject" below. Changes are
/// saved as they're made. Deleting asks first; the subject's events stay, without a subject.
struct SubjectsSettingsView: View {
    @Environment(CalendarModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The subject just added, whose name field gets the focus.
    @State private var newSubjectID: UUID? = nil
    @State private var pendingDeletion: Subject? = nil
    @State private var confirmsDeletion = false
    /// A subject that can't be deleted yet: its events would come out of their seal.
    @State private var keptSubject: Subject? = nil

    var body: some View {
        let subjects = model.library.subjects
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 10) {
                        if subjects.isEmpty {
                            SubjectsEmptyMessage()
                        }
                        ForEach(subjects) { subject in
                            SubjectSettingsCard(subject: subject, startsEditing: subject.id == newSubjectID) {
                                requestDeletion(of: subject)
                            }
                        }
                    }
                    .padding(20)
                }
                .onChange(of: newSubjectID) { _, id in
                    guard let id else { return }
                    let animation: Animation? = reduceMotion ? nil : .default
                    withAnimation(animation) {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
            bottomBar
        }
        .frame(height: 420)
        .background(Color.backgroundWindow)
        .disabled(!model.canEdit)
        .confirmationDialog(
            deletionTitle, isPresented: $confirmsDeletion, titleVisibility: .visible, presenting: pendingDeletion
        ) { subject in
            Button("Delete Subject", role: .destructive) {
                model.deleteSubject(id: subject.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { subject in
            Text("Events in “\(subject.name)” stay on your calendar, without a subject.")
        }
        .alert(
            Text("“\(keptSubject?.name ?? "")” can't be deleted yet"),
            isPresented: Binding(get: { keptSubject != nil }, set: { if !$0 { keptSubject = nil } }),
            presenting: keptSubject
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { subject in
            Text(keptMessage(for: subject))
        }
    }

    /// Why a subject's events would come out of their seal without it.
    private func keptMessage(for subject: Subject) -> String {
        if case .home(let home) = model.calendarSettings.entry(forSubject: subject.id),
            let space = model.spaces.first(where: { $0.id == home.space })
        {
            return String(
                localized:
                    "Its events keep their notes and files sealed in \(space.name). Without a subject they would have no home, and their notes would show everywhere. Give them another subject inside \(space.name), or delete them, first."
            )
        }
        return String(
            localized:
                "Its home can't be found, so its events count as sealed. Give the subject a home first, or give its events another subject."
        )
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button {
                addSubject()
            } label: {
                Label("Add Subject", systemImage: "plus")
            }
            Spacer(minLength: 8)
            Text("Quick Add picks a subject when you type its name or a keyword.")
                .font(Typography.eventTime)
                .foregroundStyle(Color.textTertiary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.backgroundSidebar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.separatorLine)
                .frame(height: 1)
        }
    }

    private var deletionTitle: Text {
        Text("Delete “\(pendingDeletion?.name ?? "")”?")
    }

    private func requestDeletion(of subject: Subject) {
        if model.reach.deletingSubjectWouldUnseal(subject.id, in: model.library) {
            keptSubject = subject
            return
        }
        pendingDeletion = subject
        confirmsDeletion = true
    }

    /// "New Subject" in the first palette color no subject uses yet.
    private func addSubject() {
        let subjects = model.library.subjects
        var used: Set<PaletteColor> = []
        for subject in subjects {
            if case .palette(let palette) = subject.color {
                used.insert(palette)
            }
        }
        let palette = PaletteColor.allCases.first { !used.contains($0) } ?? Self.palette(at: subjects.count)
        let subject = Subject(name: String(localized: "New Subject"), color: .palette(palette))
        model.addSubject(subject)
        newSubjectID = subject.id
    }

    private static func palette(at index: Int) -> PaletteColor {
        let all = PaletteColor.allCases
        return all[index % all.count]
    }
}

private struct SubjectsEmptyMessage: View {
    var body: some View {
        VStack(spacing: 6) {
            Text("No subjects yet")
                .font(.system(size: 17, weight: .semibold, design: .serif))
                .foregroundStyle(Color.textPrimary)
            Text("Add one for each course, like Physics or Biology, and one for the rest of life.")
                .font(Typography.secondary)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .accessibilityElement(children: .combine)
    }
}

/// One subject: color swatch, name and delete on top; palette and custom color, and Quick Add keywords
/// below.
///
/// The name and keywords are edited in local text and saved on every change. An empty name is never
/// saved: leaving the field puts the saved name back.
private struct SubjectSettingsCard: View {
    private enum Field: Hashable {
        case name
        case keywords
    }

    @Environment(CalendarModel.self) private var model
    private let subject: Subject
    private let startsEditing: Bool
    private let onDelete: () -> Void
    @State private var name: String
    @State private var keywords: String
    /// The custom color well. It starts at the subject's color and saves a custom color when changed.
    @State private var customColor: Color
    @FocusState private var focusedField: Field?

    init(subject: Subject, startsEditing: Bool, onDelete: @escaping () -> Void) {
        self.subject = subject
        self.startsEditing = startsEditing
        self.onDelete = onDelete
        _name = State(initialValue: subject.name)
        _keywords = State(initialValue: SubjectKeywords.text(subject.keywords))
        _customColor = State(initialValue: SubjectStyle.color(for: subject))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            nameRow
            Rectangle()
                .fill(Color.separatorLine)
                .frame(height: 1)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    SubjectRowLabel(title: "Color")
                        .gridColumnAlignment(.trailing)
                    colorRow
                }
                GridRow {
                    SubjectRowLabel(title: "Keywords")
                    keywordsField
                }
                GridRow(alignment: .firstTextBaseline) {
                    SubjectRowLabel(title: "Home")
                    SubjectHomePicker(subject: subject)
                }
            }
        }
        .padding(Metrics.Padding.formRow)
        .background {
            RoundedRectangle(cornerRadius: Metrics.Radius.formGroup, style: .continuous)
                .fill(Color.backgroundRaised)
        }
        .onAppear {
            if startsEditing {
                focusedField = .name
            }
        }
        .onChange(of: name) { _, newName in
            saveName(newName)
        }
        .onChange(of: keywords) { _, newKeywords in
            saveKeywords(newKeywords)
        }
        .onChange(of: customColor) { _, newColor in
            saveCustomColor(newColor)
        }
        .onChange(of: focusedField) { oldField, newField in
            finishEditing(from: oldField, to: newField)
        }
        .onChange(of: subject) { _, newSubject in
            follow(newSubject)
        }
    }

    private var nameRow: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(SubjectStyle.color(for: subject))
                .frame(width: 12, height: 12)
                .accessibilityHidden(true)
            TextField("Name", text: $name, prompt: Text("Subject Name"))
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
                .focused($focusedField, equals: .name)
            Button(action: onDelete) {
                Image(systemName: "minus.circle")
                    .font(.system(size: 14))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.textSecondary)
            .help("Delete Subject")
            .accessibilityLabel(Text("Delete \(subject.name)"))
        }
    }

    private var colorRow: some View {
        HStack(spacing: 6) {
            ForEach(PaletteColor.allCases, id: \.self) { palette in
                PaletteSwatchButton(palette: palette, isSelected: subject.color == .palette(palette)) {
                    save(color: .palette(palette))
                }
            }
            ColorPicker("Custom Color", selection: $customColor, supportsOpacity: false)
                .labelsHidden()
                .help("Custom Color")
                .padding(.leading, 4)
        }
    }

    private var keywordsField: some View {
        TextField("Keywords", text: $keywords, prompt: Text("e.g. phys, mechanics"))
            .textFieldStyle(.plain)
            .font(Typography.body)
            .foregroundStyle(Color.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous)
                    .fill(Color.controlFill)
            }
            .focused($focusedField, equals: .keywords)
            .help("Separate keywords with commas")
    }

    // MARK: - Saving

    private func saveName(_ newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != subject.name else { return }
        var updated = subject
        updated.name = trimmed
        model.updateSubject(updated)
    }

    private func saveKeywords(_ text: String) {
        let parsed = SubjectKeywords.parse(text)
        guard parsed != subject.keywords else { return }
        var updated = subject
        updated.keywords = parsed
        model.updateSubject(updated)
    }

    private func saveCustomColor(_ color: Color) {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
        let custom = SubjectColor.custom(
            red: Self.channel(rgb.redComponent), green: Self.channel(rgb.greenComponent),
            blue: Self.channel(rgb.blueComponent))
        guard custom != subject.color else { return }
        save(color: custom)
    }

    private func save(color: SubjectColor) {
        guard color != subject.color else { return }
        var updated = subject
        updated.color = color
        model.updateSubject(updated)
    }

    /// Leaving a field shows what was saved: the saved name instead of an empty one, tidy keywords.
    private func finishEditing(from oldField: Field?, to newField: Field?) {
        if oldField == .name, newField != .name {
            name = subject.name
        }
        if oldField == .keywords, newField != .keywords {
            keywords = SubjectKeywords.text(subject.keywords)
        }
    }

    /// Picks up changes made elsewhere, without disturbing a field being typed in.
    private func follow(_ newSubject: Subject) {
        if focusedField != .name {
            name = newSubject.name
        }
        if focusedField != .keywords {
            keywords = SubjectKeywords.text(newSubject.keywords)
        }
    }

    /// A color channel rounded to what events.json keeps (`#RRGGBB`), so a saved color compares equal after
    /// it is loaded again.
    private static func channel(_ value: CGFloat) -> Double {
        (min(max(Double(value), 0), 1) * 255).rounded() / 255
    }
}

private struct SubjectRowLabel: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(Typography.body)
            .foregroundStyle(Color.textSecondary)
            .lineLimit(1)
            .accessibilityHidden(true)
    }
}

/// A palette color to pick, with the amber ring when it's the subject's color.
private struct PaletteSwatchButton: View {
    let palette: PaletteColor
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(SubjectStyle.resource(for: palette)))
                .frame(width: 18, height: 18)
                .overlay {
                    if isSelected {
                        Circle()
                            .strokeBorder(Color.accentColor, lineWidth: Metrics.Glow.selectionRing)
                            .padding(-4)
                    }
                }
                .padding(4)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(traits)
    }

    private var name: Text {
        switch palette {
        case .clay: return Text("Clay")
        case .teal: return Text("Teal")
        case .iris: return Text("Iris")
        case .fern: return Text("Fern")
        case .rose: return Text("Rose")
        }
    }

    private var traits: AccessibilityTraits {
        isSelected ? [.isSelected] : []
    }
}

/// Quick Add keywords as one comma-separated line.
enum SubjectKeywords {
    /// "phys, mechanics".
    static func text(_ keywords: [String]) -> String {
        keywords.joined(separator: ", ")
    }

    /// The words between commas, trimmed, without empty or repeated ones (ignoring case).
    static func parse(_ text: String) -> [String] {
        var seen: Set<String> = []
        var keywords: [String] = []
        for part in text.split(separator: ",") {
            let word = part.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = word.lowercased()
            guard !word.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            keywords.append(word)
        }
        return keywords
    }
}

/// A subject's home: "No home", or a space (and a folder in it, chosen from the folders the space has).
/// A home that can't be used (its space is gone, or library.json can't say) is shown with a warning, and the
/// subject's events' notes and files stay hidden until another is chosen.
struct SubjectHomePicker: View {
    @Environment(CalendarModel.self) private var model
    @Environment(AppModel.self) private var app
    let subject: Subject

    var body: some View {
        let entry = model.calendarSettings.entry(forSubject: subject.id)
        VStack(alignment: .leading, spacing: 4) {
            Menu {
                Button("No Home") {
                    model.setHome(nil, forSubject: subject.id)
                }
                Divider()
                ForEach(model.spaces) { space in
                    let folders = app.folders[space.id] ?? []
                    if folders.isEmpty || space.isSealed {
                        Button(space.name) {
                            model.setHome(SubjectHome(space: space.id), forSubject: subject.id)
                        }
                    } else {
                        Menu(space.name) {
                            Button(space.name) {
                                model.setHome(SubjectHome(space: space.id), forSubject: subject.id)
                            }
                            Divider()
                            ForEach(folders, id: \.self) { folder in
                                Button(folder.components.joined(separator: " › ")) {
                                    model.setHome(SubjectHome(space: space.id, folder: folder), forSubject: subject.id)
                                }
                            }
                        }
                    }
                }
            } label: {
                Text(verbatim: label(entry))
            }
            .fixedSize()
            if isMissing(entry) {
                Label(
                    "Its home is gone. Its events' notes and files are hidden until you choose one.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(Typography.footnote)
                .foregroundStyle(Color.accentText)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func label(_ entry: SubjectHomeEntry) -> String {
        switch entry {
        case .none:
            return String(localized: "No home")
        case .unreadable:
            return String(localized: "Unknown")
        case .home(let home):
            guard let space = model.spaces.first(where: { $0.id == home.space }) else {
                return String(localized: "Missing space")
            }
            // A sealed space's folders are named only inside it.
            if space.isSealed {
                return space.name
            }
            return ([space.name] + home.folder.components).joined(separator: " › ")
        }
    }

    private func isMissing(_ entry: SubjectHomeEntry) -> Bool {
        switch entry {
        case .none: false
        case .unreadable: true
        case .home(let home): !model.spaces.contains { $0.id == home.space }
        }
    }
}
