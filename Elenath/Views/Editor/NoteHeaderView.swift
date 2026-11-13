import ElenathCore
import SwiftUI

/// Above a note's text: its title, which is its file name and is edited in place, and a row with its
/// place, its kind, its tags and when it was last edited.
struct NoteHeaderView: View {
    /// The header's height in the text view.
    static let height: CGFloat = 86

    let session: EditorSession
    /// Moves the keyboard to the text: Return in the title.
    let focusText: @MainActor () -> Void
    @Environment(AppModel.self) private var model
    @State private var title = ""
    @State private var isAddingTag = false
    @State private var newTag = ""
    @FocusState private var isTitleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Untitled", text: $title)
                .textFieldStyle(.plain)
                .font(Typography.noteTitle)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
                .focused($isTitleFocused)
                .disabled(session.isReadOnly)
                .onSubmit {
                    commitTitle()
                    focusText()
                }
                .accessibilityLabel(Text("Title"))
            details
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            title = session.ref.title
            if model.pendingTitleFocus == session.ref {
                model.pendingTitleFocus = nil
                isTitleFocused = true
            }
        }
        .onChange(of: session.ref) { _, ref in
            if !isTitleFocused {
                title = ref.title
            }
        }
        .onChange(of: isTitleFocused) { _, isFocused in
            if !isFocused {
                commitTitle()
            }
        }
    }

    private var details: some View {
        HStack(spacing: 12) {
            PlaceLabel(container: session.ref.container, folder: session.ref.path.folder)
            kindMenu
            tagList
            Spacer(minLength: 8)
            if let modified = session.modified {
                Text("Edited \(DateText.short(modified, now: model.timeSource.now))")
                    .font(Typography.secondary)
                    .monospacedDigit()
                    .foregroundStyle(Color.textTertiary)
                    .lineLimit(1)
            }
        }
        .frame(height: 22)
    }

    private var kindMenu: some View {
        Menu {
            ForEach(NoteKind.allCases, id: \.self) { kind in
                Button {
                    session.setKind(kind)
                } label: {
                    Label(KindStyle.name(for: kind), systemImage: KindStyle.symbol(for: kind))
                }
            }
        } label: {
            Label(KindStyle.name(for: session.kind), systemImage: KindStyle.symbol(for: session.kind))
                .font(Typography.secondary)
                .foregroundStyle(Color.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(session.isReadOnly)
        .accessibilityLabel(Text("Kind"))
    }

    private var tagList: some View {
        HStack(spacing: 6) {
            ForEach(session.tags, id: \.self) { tag in
                Text(verbatim: "#\(tag)")
                    .font(Typography.footnote)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.controlFill, in: Capsule())
                    .contextMenu {
                        Button("Remove Tag") {
                            session.setTags(session.tags.filter { $0 != tag })
                        }
                        .disabled(session.isReadOnly)
                    }
            }
            if !session.isReadOnly {
                Button {
                    newTag = ""
                    isAddingTag = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.textTertiary)
                        .frame(width: 18, height: 18)
                        .background(Color.controlFill, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Add a Tag")
                .accessibilityLabel(Text("Add a Tag"))
                .popover(isPresented: $isAddingTag, arrowEdge: .bottom) {
                    TextField("Tag", text: $newTag)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                        .padding(Metrics.Padding.popover)
                        .onSubmit {
                            addTag()
                        }
                }
            }
        }
        .lineLimit(1)
    }

    private func addTag() {
        let tag = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        isAddingTag = false
        guard !tag.isEmpty else { return }
        session.setTags(session.tags + [tag])
    }

    private func commitTitle() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            title = session.ref.title
            return
        }
        guard trimmed != session.ref.title, !session.isReadOnly else { return }
        model.rename(session.ref, to: trimmed)
    }
}

/// Below a note's text: the notes that link to it, each with the line that holds the link. Absent when
/// nothing links here.
struct BacklinksView: View {
    let note: NoteRef
    let revision: Int
    /// Reports the height the list takes, so the text view can make room for it.
    let onHeightChange: @MainActor (CGFloat) -> Void
    @Environment(AppModel.self) private var model
    @State private var backlinks: [Backlink] = []

    var body: some View {
        let report = onHeightChange
        VStack(alignment: .leading, spacing: 4) {
            if !backlinks.isEmpty {
                Rectangle()
                    .fill(Color.separatorLine)
                    .frame(height: 1)
                    .padding(.bottom, 12)
                Text("Linked from")
                    .font(Typography.caption)
                    .foregroundStyle(Color.textTertiary)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, 2)
                ForEach(Array(backlinks.enumerated()), id: \.offset) { _, link in
                    Button {
                        model.open(link.source.note)
                    } label: {
                        BacklinkRow(link: link)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            MainActor.assumeIsolated {
                report(height)
            }
        }
        .task(id: Key(note: note, revision: revision)) {
            guard let services = model.services else { return }
            backlinks = (try? await services.retrieval.backlinks(to: note)) ?? []
        }
    }

    private struct Key: Hashable {
        var note: NoteRef
        var revision: Int
    }
}

private struct BacklinkRow: View {
    let link: Backlink
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                SpaceDot(space: model.space(of: link.source.note.container), size: 6)
                Text(verbatim: link.source.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
            }
            Text(verbatim: link.context)
                .font(Typography.secondary)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
