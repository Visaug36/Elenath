import ElenathCore
import SwiftUI

/// `house` and where the event's notes go: "Uni › Physics" with the space's dot, or "No home · notes go to
/// the Inbox". Shown only where the event's content may be read.
struct EventHomeRow: View {
    @Environment(CalendarModel.self) private var model
    let home: SubjectHome?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "house")
                .font(.system(size: 12))
                .foregroundStyle(Color.textSecondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            if let home, let space = model.spaces.first(where: { $0.id == home.space }) {
                SpaceDot(space: space, size: 7)
                Text(verbatim: place(space: space, folder: home.folder))
                    .font(Typography.body)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
            } else {
                Text("No home · notes go to the Inbox")
                    .font(Typography.body)
                    .foregroundStyle(Color.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Home"))
    }

    private func place(space: Space, folder: ItemPath) -> String {
        ([space.name] + folder.components).joined(separator: " › ")
    }
}

/// "Notes for this event": the notes linked to this occurrence, newest first, and "New Note for This
/// Event", which makes one in the event's home (the Inbox without one) and opens it.
struct EventLinkedNotesSection: View {
    @Environment(AppModel.self) private var app
    @Environment(CalendarModel.self) private var model
    let occurrence: Occurrence
    let home: SubjectHome?
    /// Called after a note opens, so the popover closes.
    let onOpen: () -> Void
    @State private var notes: [NoteHit] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notes for this event")
                .font(Typography.caption)
                .foregroundStyle(Color.textTertiary)
                .accessibilityAddTraits(.isHeader)
            ForEach(notes, id: \.note) { hit in
                Button {
                    app.open(hit.note)
                    onOpen()
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: hit.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.textPrimary)
                            .lineLimit(1)
                        if !hit.preview.isEmpty {
                            Text(verbatim: hit.preview)
                                .font(Typography.secondary)
                                .foregroundStyle(Color.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open Note")
            }
            Button {
                app.newNote(for: occurrence, home: home)
                onOpen()
            } label: {
                Label("New Note for This Event", systemImage: "square.and.pencil")
                    .font(Typography.secondary)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.accentText)
            .disabled(!app.canEdit(home.map { .space($0.space) } ?? .inbox))
        }
        .task(id: Key(occurrence: occurrence.id, revision: app.contentRevision, workplace: model.workplace)) {
            notes = await app.notes(linkedTo: occurrence, from: model.workplace)
        }
    }

    private struct Key: Hashable {
        var occurrence: Occurrence.ID
        var revision: Int
        var workplace: Workplace
    }
}

/// For an event whose files' names may not be read here: "Files · 3" and Open Files, which opens the
/// event's folder in Finder. The count and the folder cross the seal; the names don't.
struct EventSealedFilesRow: View {
    @Environment(FilesController.self) private var files
    let occurrence: Occurrence

    var body: some View {
        let count = files.fileCount(for: occurrence)
        HStack(spacing: 8) {
            Text("Files")
                .font(Typography.caption)
                .foregroundStyle(Color.textTertiary)
            if let count {
                Text(verbatim: "· \(count)")
                    .font(Typography.caption)
                    .monospacedDigit()
                    .foregroundStyle(Color.textTertiary)
            }
            Spacer(minLength: 8)
            Button {
                files.revealInFinder(occurrence)
            } label: {
                Label("Open Files", systemImage: "folder")
                    .font(Typography.secondary)
            }
            .buttonStyle(.borderless)
            .disabled((count ?? 0) == 0)
            .help("Show the event's folder in Finder")
        }
        .accessibilityElement(children: .combine)
    }
}

/// Where an event's notes and files are, when they may not be read here: kept in its sealed space (with
/// "Open in Red Cross"), outside the sealed space the calendar is working in (with "Leave Red Cross"), or
/// behind a home that is gone (with Open Settings).
struct EventSealedCard: View {
    @Environment(CalendarModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    let event: Event

    var body: some View {
        let reason = Reason(event: event, model: model)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: reason.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(reason.tint)
                    .accessibilityHidden(true)
                Text(reason.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(reason.message)
                .font(Typography.secondary)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(reason.buttonTitle) {
                act(reason)
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.backgroundWindow, in: RoundedRectangle(cornerRadius: Metrics.Radius.card))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.Radius.card)
                .strokeBorder(Color.separatorLine, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private func act(_ reason: Reason) {
        switch reason.kind {
        case .keptIn(let space):
            model.work(in: .space(space.id))
        case .outside:
            model.work(in: .everywhere)
        case .missingHome:
            openSettings()
        }
    }

    private struct Reason {
        enum Kind {
            case keptIn(Space)
            case outside(Space?)
            case missingHome
        }

        var kind: Kind

        @MainActor
        init(event: Event, model: CalendarModel) {
            let reach = model.reach
            let home = reach.home(of: event)
            var current: Space?
            if case .space(let id) = model.workplace {
                current = model.spaces.first { $0.id == id }
            }
            if reach.hasMissingHome(event) {
                kind = .missingHome
            } else if let current, current.isSealed, home?.space != current.id {
                // Working inside a sealed space: nothing from outside it shows here.
                kind = .outside(current)
            } else if let home, let space = model.spaces.first(where: { $0.id == home.space }),
                model.workplace != .space(space.id)
            {
                kind = .keptIn(space)
            } else {
                kind = .outside(current)
            }
        }

        var symbol: String {
            switch kind {
            case .keptIn, .outside: "lock.fill"
            case .missingHome: "exclamationmark.triangle"
            }
        }

        @MainActor var tint: Color {
            switch kind {
            case .keptIn(let space): SpaceStyle.color(for: space)
            case .outside(let space): SpaceStyle.color(for: space)
            case .missingHome: Color.accentText
            }
        }

        var title: String {
            switch kind {
            case .keptIn(let space): String(localized: "Kept in \(space.name)")
            case .outside(let space?): String(localized: "Not shown inside \(space.name)")
            case .outside(nil): String(localized: "Not shown here")
            case .missingHome: String(localized: "Its home is gone")
            }
        }

        var message: String {
            switch kind {
            case .keptIn:
                String(localized: "This event's notes, files and linked notes are sealed in its space.")
            case .outside:
                String(localized: "This event's notes and files are outside the sealed space you're working in.")
            case .missingHome:
                String(localized: "Choose a home for its subject in Settings to see this event's notes and files.")
            }
        }

        var buttonTitle: String {
            switch kind {
            case .keptIn(let space): String(localized: "Open in \(space.name)")
            case .outside(let space?): String(localized: "Leave \(space.name)")
            case .outside(nil): String(localized: "Show Everywhere")
            case .missingHome: String(localized: "Open Settings")
            }
        }
    }
}
