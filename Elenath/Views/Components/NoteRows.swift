import ElenathCore
import SwiftUI

/// A note in a list: the kind's symbol, the title, the first line, and at the right where it is and
/// when it last changed.
struct NoteRowView: View {
    let note: NoteRef
    let title: String
    let kind: NoteKind
    let preview: String
    let modified: Date?
    /// Whether to say which space and folder the note is in: for lists that span several places.
    var showsPlace = false
    @Environment(AppModel.self) private var model

    init(hit: NoteHit, showsPlace: Bool = false) {
        note = hit.note
        title = hit.title
        kind = hit.kind
        preview = hit.preview
        modified = hit.modified
        self.showsPlace = showsPlace
    }

    init(note: NoteRef, title: String, kind: NoteKind, preview: String, modified: Date?, showsPlace: Bool = false) {
        self.note = note
        self.title = title
        self.kind = kind
        self.preview = preview
        self.modified = modified
        self.showsPlace = showsPlace
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: KindStyle.symbol(for: kind))
                .font(.system(size: 13))
                .foregroundStyle(kind == .note ? Color.textSecondary : Color.accentText)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                if !preview.isEmpty {
                    Text(verbatim: preview)
                        .font(Typography.secondary)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                }
                if showsPlace {
                    PlaceLabel(container: note.container, folder: note.path.folder)
                }
            }
            Spacer(minLength: 8)
            Text(verbatim: DateText.short(modified, now: model.timeSource.now))
                .font(Typography.footnote)
                .monospacedDigit()
                .foregroundStyle(Color.textTertiary)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// The space's dot and "Uni › Physics".
struct PlaceLabel: View {
    let container: Container
    let folder: ItemPath
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 5) {
            SpaceDot(space: model.space(of: container), size: 6)
            Text(verbatim: model.placeName(container, folder))
                .font(Typography.footnote)
                .foregroundStyle(Color.textTertiary)
                .lineLimit(1)
        }
    }
}

/// A row that opens what it shows when it is clicked, with a hover fill and a drag of the file itself.
struct OpenableRow<Content: View>: View {
    let dragURL: URL?
    let action: () -> Void
    @ViewBuilder var content: Content
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    if isHovered {
                        RoundedRectangle(cornerRadius: Metrics.Radius.listRow, style: .continuous)
                            .fill(Color.controlFill)
                    }
                }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .modifier(DragFile(url: dragURL))
    }
}

/// Lets a row be dragged as its file: onto a folder in the sidebar to move it, or out to Finder to copy
/// it.
private struct DragFile: ViewModifier {
    let url: URL?

    func body(content: Content) -> some View {
        if let url {
            content.draggable(url)
        } else {
            content
        }
    }
}

/// What can be done to a note from a list.
struct NoteMenu: View {
    let note: NoteRef
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("Open") {
            model.open(note)
        }
        Divider()
        Button("Rename…") {
            RenamePrompt.run(title: String(localized: "Rename Note"), current: note.title) { title in
                model.rename(note, to: title)
            }
        }
        MoveMenu(title: note.container == .inbox ? Text("File to") : Text("Move to")) { container, folder in
            model.move(note, to: folder, in: container)
        }
        Button("Show in Finder") {
            model.revealInFinder(note.path, in: note.container)
        }
        Divider()
        Button("Move to Trash") {
            model.trash(note)
        }
        .disabled(!model.canEdit(note.container))
    }
}

/// A menu of every space and its folders, to move or file something there.
struct MoveMenu: View {
    let title: Text
    let choose: (Container, ItemPath) -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            ForEach(model.spaces.filter { !$0.isReadOnly }) { space in
                let container = Container.space(space.id)
                let folders = model.folders[space.id] ?? []
                if folders.isEmpty {
                    Button {
                        choose(container, .root)
                    } label: {
                        Label(space.name, systemImage: SpaceStyle.symbol(for: space))
                    }
                } else {
                    Menu {
                        Button {
                            choose(container, .root)
                        } label: {
                            Text("Top of \(space.name)")
                        }
                        Divider()
                        ForEach(folders, id: \.self) { folder in
                            Button {
                                choose(container, folder)
                            } label: {
                                Label(folder.description, systemImage: "folder")
                            }
                        }
                    } label: {
                        Label(space.name, systemImage: SpaceStyle.symbol(for: space))
                    }
                }
            }
            if model.spaces.isEmpty {
                Text("No spaces yet")
            }
        } label: {
            title
        }
    }
}

/// A `BackgroundRaised` card with an 11 pt label: what Today and a space's page are made of.
struct SectionCard<Content: View, Accessory: View>: View {
    let title: Text
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                title
                    .font(Typography.caption)
                    .foregroundStyle(Color.textTertiary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                accessory
            }
            .padding(.horizontal, 10)
            content
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.backgroundRaised, in: RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous)
                .strokeBorder(Color.separatorLine, lineWidth: 1)
        }
    }
}

/// A line for a card that has nothing to show.
struct CardPlaceholder: View {
    let text: Text

    var body: some View {
        text
            .font(Typography.secondary)
            .foregroundStyle(Color.textTertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
    }
}

/// An open task in a list: a box to tick, the task, and the note it is in.
struct TaskRowView: View {
    let task: TaskHit
    var showsPlace = true
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button {
                model.toggleTask(in: task.note.note, at: task.location, text: task.text)
            } label: {
                Image(systemName: "square")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Mark as done: \(task.text)"))
            .disabled(!model.canEdit(task.note.note.container))
            Button {
                model.open(task.note.note, highlighting: [task.text])
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: task.text.isEmpty ? String(localized: "Empty task") : task.text)
                        .font(Typography.body)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 5) {
                        if showsPlace {
                            SpaceDot(space: model.space(of: task.note.note.container), size: 6)
                        }
                        Text(verbatim: task.note.title)
                            .font(Typography.footnote)
                            .foregroundStyle(Color.textTertiary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 10)
    }
}

extension SectionCard where Accessory == EmptyView {
    init(title: Text, @ViewBuilder content: () -> Content) {
        self.init(title: title, accessory: { EmptyView() }, content: content)
    }
}
