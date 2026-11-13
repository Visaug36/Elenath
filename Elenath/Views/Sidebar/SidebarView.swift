import ElenathCore
import SwiftUI

/// The sidebar: Today, the Inbox with its count, the spaces with their folders, and the tags that can be
/// seen from where the user is. On the starry sidebar background.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    /// The spaces and folders whose folders are shown.
    @State private var expanded: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                SidebarRow(
                    title: Text("Today"), symbol: "sun.horizon", tint: Color.textSecondary,
                    isSelected: model.route == .today
                ) {
                    model.go(to: .today)
                }
                InboxRow()
                SidebarSectionLabel(title: Text("Spaces")) {
                    Button {
                        model.spaceSheet = .new
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("New Space")
                    .accessibilityLabel(Text("New Space"))
                    .disabled(!model.canEdit)
                }
                ForEach(model.spaces) { space in
                    SpaceRows(space: space, expanded: $expanded)
                }
                if !model.tags.isEmpty {
                    SidebarSectionLabel(title: Text("Tags")) {
                        EmptyView()
                    }
                    ForEach(model.tags, id: \.tag) { tag in
                        TagRow(tag: tag)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 16)
        }
        .starryBackground(.backgroundSidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ImportStatusCard()
        }
        .onChange(of: model.route, initial: true) {
            expandCurrentSpace()
        }
    }

    /// The space the user is in shows its folders.
    private func expandCurrentSpace() {
        if case .space(let id) = model.workplace {
            expanded.insert(id.rawValue.uuidString)
        }
    }
}

/// An 11 pt label over a group of rows, with room for a small button at the right.
private struct SidebarSectionLabel<Accessory: View>: View {
    let title: Text
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack {
            title
                .font(Typography.caption)
                .foregroundStyle(Color.textTertiary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            accessory
        }
        .padding(.horizontal, 8)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }
}

/// One row of the sidebar: a symbol, a name, and something at the right. The selected row has an
/// `AccentSoft` fill and semibold text.
struct SidebarRow<Trailing: View>: View {
    let title: Text
    let symbol: String
    let tint: Color
    let isSelected: Bool
    var indent: CGFloat = 0
    @ViewBuilder var trailing: Trailing
    let action: () -> Void

    init(
        title: Text, symbol: String, tint: Color, isSelected: Bool, indent: CGFloat = 0,
        @ViewBuilder trailing: () -> Trailing, action: @escaping () -> Void
    ) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.isSelected = isSelected
        self.indent = indent
        self.trailing = trailing()
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(tint)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                title
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                trailing
            }
            .padding(.leading, 8 + indent)
            .padding(.trailing, 8)
            .frame(height: 28)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: Metrics.Radius.listRow, style: .continuous)
                        .fill(Color.accentSoft)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: Metrics.Radius.listRow, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension SidebarRow where Trailing == EmptyView {
    init(
        title: Text, symbol: String, tint: Color, isSelected: Bool, indent: CGFloat = 0, action: @escaping () -> Void
    ) {
        self.init(
            title: title, symbol: symbol, tint: tint, isSelected: isSelected, indent: indent, trailing: { EmptyView() },
            action: action)
    }
}

/// The Inbox, with how many items wait in it.
private struct InboxRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let count = model.inboxCount
        SidebarRow(
            title: Text("Inbox"), symbol: count > 0 ? "tray.full" : "tray", tint: Color.textSecondary,
            isSelected: isSelected
        ) {
            if count > 0 {
                Text(verbatim: "\(count)")
                    .font(Typography.footnote)
                    .monospacedDigit()
                    .foregroundStyle(Color.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.controlFill, in: Capsule())
            }
        } action: {
            model.go(to: .inbox)
        }
        .libraryDropTarget(.inbox)
        .accessibilityLabel(Text("Inbox, \(count) items"))
    }

    private var isSelected: Bool {
        switch model.route {
        case .inbox: true
        case .note(let note): note.container == .inbox
        case .folder(.inbox, _): true
        default: false
        }
    }
}

/// A space and, when it is opened up, its folders.
private struct SpaceRows: View {
    let space: Space
    @Binding var expanded: Set<String>
    @Environment(AppModel.self) private var model

    var body: some View {
        let container = Container.space(space.id)
        let folders = model.folders[space.id] ?? []
        let key = space.id.rawValue.uuidString
        SidebarRow(
            title: Text(verbatim: space.name), symbol: SpaceStyle.symbol(for: space),
            tint: SpaceStyle.color(for: space),
            isSelected: model.route == .folder(container, .root)
        ) {
            if space.isSealed {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.textTertiary)
                    .accessibilityHidden(true)
            }
            if !folders.isEmpty {
                DisclosureChevron(isExpanded: expanded.contains(key)) {
                    toggle(key)
                }
            }
        } action: {
            model.go(to: .folder(container, .root))
            expanded.insert(key)
        }
        .libraryDropTarget(container)
        .accessibilityLabel(space.isSealed ? Text("\(space.name), sealed space") : Text("\(space.name), space"))
        .contextMenu {
            SpaceMenu(space: space)
        }
        if expanded.contains(key) {
            FolderRows(container: container, parent: .root, folders: folders, depth: 1, expanded: $expanded)
        }
    }

    private func toggle(_ key: String) {
        if expanded.contains(key) {
            expanded.remove(key)
        } else {
            expanded.insert(key)
        }
    }
}

/// The folders directly inside one folder, each with its own folders under it when it is opened up.
private struct FolderRows: View {
    let container: Container
    let parent: ItemPath
    let folders: [ItemPath]
    let depth: Int
    @Binding var expanded: Set<String>
    @Environment(AppModel.self) private var model

    var body: some View {
        let children = folders.filter { $0.folder == parent && !$0.isRoot }
        ForEach(children, id: \.self) { folder in
            let key = "\(container)/\(folder.description)"
            let hasChildren = folders.contains { $0.folder == folder }
            SidebarRow(
                title: Text(verbatim: folder.name), symbol: "folder", tint: Color.textSecondary,
                isSelected: model.route == .folder(container, folder), indent: CGFloat(depth) * 16
            ) {
                if hasChildren {
                    DisclosureChevron(isExpanded: expanded.contains(key)) {
                        if expanded.contains(key) {
                            expanded.remove(key)
                        } else {
                            expanded.insert(key)
                        }
                    }
                }
            } action: {
                model.go(to: .folder(container, folder))
            }
            .libraryDropTarget(container, folder)
            .contextMenu {
                FolderMenu(container: container, folder: folder)
            }
            if expanded.contains(key) {
                FolderRows(
                    container: container, parent: folder, folders: folders, depth: depth + 1, expanded: $expanded)
            }
        }
    }
}

private struct DisclosureChevron: View {
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.textTertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? Text("Hide folders") : Text("Show folders"))
    }
}

/// A tag, with how many notes have it. A nested tag ("uni/physics") sits under its parent.
private struct TagRow: View {
    let tag: TagCount
    @Environment(AppModel.self) private var model

    var body: some View {
        let depth = tag.tag.split(separator: "/").count - 1
        let shown = tag.tag.split(separator: "/").last.map(String.init) ?? tag.tag
        SidebarRow(
            title: Text(verbatim: shown), symbol: "number", tint: Color.textSecondary, isSelected: isSelected,
            indent: CGFloat(depth) * 16
        ) {
            Text(verbatim: "\(tag.count)")
                .font(Typography.footnote)
                .monospacedDigit()
                .foregroundStyle(Color.textTertiary)
        } action: {
            model.go(to: .tag(tag.tag, model.workplace))
        }
        .accessibilityLabel(Text("Tag \(tag.tag), \(tag.count) notes"))
    }

    private var isSelected: Bool {
        if case .tag(let name, _) = model.route {
            return name == tag.tag
        }
        return false
    }
}

/// What can be done to a space from the sidebar.
struct SpaceMenu: View {
    let space: Space
    @Environment(AppModel.self) private var model

    var body: some View {
        let container = Container.space(space.id)
        Button("New Note") {
            model.newNote(in: container, folder: .root)
        }
        Button("New Folder") {
            model.newFolder(in: container, folder: .root)
        }
        Divider()
        Button("Edit Space…") {
            model.spaceSheet = .edit(space.id)
        }
        Button("Show in Finder") {
            model.revealInFinder(.root, in: container)
        }
        Divider()
        Button("Move to Trash") {
            model.trashSpace(space.id)
        }
        .disabled(!model.canEdit(container))
    }
}

/// What can be done to a folder from the sidebar or a list.
struct FolderMenu: View {
    let container: Container
    let folder: ItemPath
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("New Note") {
            model.newNote(in: container, folder: folder)
        }
        Button("New Folder") {
            model.newFolder(in: container, folder: folder)
        }
        Divider()
        Button("Rename…") {
            RenamePrompt.run(title: String(localized: "Rename Folder"), current: folder.name) { newName in
                model.renameFolder(folder, in: container, to: newName)
            }
        }
        Button("Show in Finder") {
            model.revealInFinder(folder, in: container)
        }
        Divider()
        Button("Move to Trash") {
            model.trashItem(folder, in: container)
        }
        .disabled(!model.canEdit(container))
    }
}

/// How an import is going, at the foot of the sidebar.
private struct ImportStatusCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let status = model.importStatus {
            VStack(alignment: .leading, spacing: 6) {
                switch status.phase {
                case .running(let completed, let total, let currentName):
                    Text("Importing \(completed) of \(total)…")
                        .font(Typography.secondary)
                        .monospacedDigit()
                        .foregroundStyle(Color.textPrimary)
                    ProgressView(value: Double(completed), total: Double(max(total, 1)))
                        .tint(Color.accentColor)
                    HStack {
                        Text(verbatim: currentName ?? "")
                            .font(Typography.footnote)
                            .foregroundStyle(Color.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Cancel") {
                            model.cancelImport()
                        }
                        .buttonStyle(.plain)
                        .font(Typography.footnote)
                        .foregroundStyle(Color.accentText)
                    }
                case .finished(let notes, let files, let skipped, let failed):
                    Text("Imported \(notes + files) items into \(status.destinationName).")
                        .font(Typography.secondary)
                        .foregroundStyle(Color.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if skipped + failed > 0 {
                        Text("\(skipped) were skipped and \(failed) could not be read.")
                            .font(Typography.footnote)
                            .foregroundStyle(Color.textSecondary)
                    }
                    Text("The originals are where they were.")
                        .font(Typography.footnote)
                        .foregroundStyle(Color.textTertiary)
                    HStack {
                        Button("Show") {
                            model.go(to: status.destination)
                            model.dismissImportStatus()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentText)
                        Spacer()
                        Button("Done") {
                            model.dismissImportStatus()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.textSecondary)
                    }
                    .font(Typography.footnote)
                }
            }
            .padding(12)
            .background(
                Color.backgroundRaised, in: RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous)
                    .strokeBorder(Color.separatorLine, lineWidth: 1)
            }
            .padding(10)
        }
    }
}
