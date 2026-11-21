import AppKit
import ElenathCore
import QuickLook
import SwiftUI

/// The files in an event's folder (DESIGN.md screen 6): the system icon, the name, and "PDF document ·
/// 2.4 MB" on rows with radius 7.
///
/// - A click selects a row (an `AccentSoft` background with an `eye` "Space" hint), a double-click or
///   Return opens the file, Space shows or hides Quick Look, ↑ / ↓ move the selection.
/// - The context menu has Open, Show in Finder and Move to Trash… (which asks first). Delete asks too.
/// - Up to six rows show at once; more scroll.
///
/// `isFocused` tells the popover when the list has keyboard focus, so Return opens a file rather than
/// pressing the popover's default button.
struct EventFileList: View {
    @Environment(CalendarModel.self) private var model
    @Environment(FilesController.self) private var files
    let items: [EventFile]
    @Binding var isFocused: Bool
    @FocusState private var hasFocus: Bool
    @State private var selection: URL? = nil
    @State private var previewURL: URL? = nil
    @State private var fileToTrash: EventFile? = nil
    @State private var confirmsTrash = false

    /// The height of one row, and how many show before the list scrolls.
    static let rowHeight: CGFloat = 42
    static let visibleRows = 6
    private static let rowSpacing: CGFloat = 2

    var body: some View {
        scrollingRows
            .focusable()
            .focused($hasFocus)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) {
                moveSelection(by: -1)
            }
            .onKeyPress(.downArrow) {
                moveSelection(by: 1)
            }
            .onKeyPress(.space) {
                toggleQuickLook()
            }
            .onKeyPress(.return) {
                openSelection()
            }
            .onDeleteCommand {
                requestTrash(selectedFile)
            }
            .quickLookPreview($previewURL, in: items.map(\.url))
            .modifier(EventFileTrashConfirmation(isPresented: $confirmsTrash, file: fileToTrash))
            .onDisappear {
                // The list goes away once its last file is trashed; Return belongs to Edit again.
                isFocused = false
            }
            .onChange(of: hasFocus) { _, focused in
                isFocused = focused
                if focused && selectedFile == nil {
                    selection = items.first?.url
                }
            }
            .onChange(of: previewURL) { _, shown in
                if let shown {
                    selection = shown
                }
            }
            .onChange(of: items) {
                if let selected = selection, !items.contains(where: { $0.url == selected }) {
                    selection = nil
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Files"))
    }

    private var scrollingRows: some View {
        ScrollViewReader { proxy in
            ScrollView {
                rows
            }
            .scrollIndicators(.automatic)
            .frame(height: listHeight)
            .onChange(of: selection) { _, selected in
                if let selected {
                    proxy.scrollTo(selected)
                }
            }
        }
    }

    private var rows: some View {
        VStack(spacing: Self.rowSpacing) {
            ForEach(items) { file in
                EventFileRow(file: file, isSelected: selection == file.url, showsHint: hasFocus)
                    .id(file.url)
                    .onTapGesture {
                        handleClick(on: file)
                    }
                    .contextMenu {
                        EventFileMenu(file: file, onTrash: { requestTrash(file) })
                    }
                    .accessibilityAction(.default) {
                        files.open(file)
                    }
                    .accessibilityAction(named: Text("Quick Look")) {
                        selection = file.url
                        previewURL = file.url
                    }
                    .accessibilityAction(named: Text("Show in Finder")) {
                        files.reveal(file)
                    }
                    .accessibilityAction(named: Text("Move to Trash")) {
                        requestTrash(file)
                    }
            }
        }
    }

    private var listHeight: CGFloat {
        let count = CGFloat(min(max(items.count, 1), Self.visibleRows))
        return count * Self.rowHeight + (count - 1) * Self.rowSpacing
    }

    private var selectedFile: EventFile? {
        guard let selection else { return nil }
        return items.first { $0.url == selection }
    }

    // MARK: - Actions

    private func handleClick(on file: EventFile) {
        hasFocus = true
        selection = file.url
        if CalendarClick.isDoubleClick() {
            files.open(file)
        } else if previewURL != nil {
            previewURL = file.url
        }
    }

    private func moveSelection(by step: Int) -> KeyPress.Result {
        guard !items.isEmpty else { return .ignored }
        let current = items.firstIndex { $0.url == selection }
        let next: Int
        if let current {
            next = min(max(current + step, 0), items.count - 1)
        } else {
            next = step > 0 ? 0 : items.count - 1
        }
        selection = items[next].url
        if previewURL != nil {
            previewURL = items[next].url
        }
        return .handled
    }

    private func toggleQuickLook() -> KeyPress.Result {
        if previewURL != nil {
            previewURL = nil
            return .handled
        }
        guard let file = selectedFile ?? items.first else { return .ignored }
        selection = file.url
        previewURL = file.url
        return .handled
    }

    private func openSelection() -> KeyPress.Result {
        guard let file = selectedFile else { return .ignored }
        files.open(file)
        return .handled
    }

    /// Asks before moving `file` to the Trash.
    private func requestTrash(_ file: EventFile?) {
        guard let file, model.canEdit else { return }
        fileToTrash = file
        confirmsTrash = true
    }
}

/// One file: its icon (32 pt), name (13 pt) and "PDF document · 2.4 MB".
private struct EventFileRow: View {
    let file: EventFile
    let isSelected: Bool
    /// The "Space" hint shows on the selected row while the list has keyboard focus.
    let showsHint: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.Radius.listRow, style: .continuous)
        HStack(spacing: 10) {
            Image(nsImage: FileIcons.icon(for: file))
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name)
                    .font(Typography.body)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(FileLabels.details(of: file))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if isSelected && showsHint {
                QuickLookHint()
            }
        }
        .padding(.horizontal, 6)
        .frame(height: EventFileList.rowHeight)
        .background {
            shape.fill(isSelected ? Color.accentSoft : Color.clear)
        }
        .contentShape(shape)
        .help(file.name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(FileLabels.accessibilityLabel(of: file))
        .accessibilityAddTraits(CalendarEventStyle.traits(isSelected: isSelected))
        .accessibilityHint(Text("Opens the file"))
    }
}

/// `eye` "Space": Space shows the selected file in Quick Look.
private struct QuickLookHint: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "eye")
            Text("Space", comment: "The Space bar, which shows a file in Quick Look")
        }
        .font(.system(size: 11))
        .foregroundStyle(Color.accentText)
        .accessibilityHidden(true)
    }
}

/// Open, Show in Finder, then Move to Trash… (which asks first).
private struct EventFileMenu: View {
    @Environment(FilesController.self) private var files
    @Environment(CalendarModel.self) private var model
    let file: EventFile
    let onTrash: () -> Void

    var body: some View {
        Button("Open") {
            files.open(file)
        }
        Button("Show in Finder") {
            files.reveal(file)
        }
        Divider()
        Button("Move to Trash…", role: .destructive) {
            onTrash()
        }
        .disabled(!model.canEdit)
    }
}

/// "Move “notes.md” to the Trash?" before a file goes to the Trash. It is never deleted for good: it can
/// be put back from the Trash in Finder.
private struct EventFileTrashConfirmation: ViewModifier {
    @Environment(FilesController.self) private var files
    @Binding var isPresented: Bool
    let file: EventFile?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            title, isPresented: $isPresented, titleVisibility: .visible, presenting: file
        ) { item in
            Button("Move to Trash", role: .destructive) {
                files.moveToTrash(item)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("You can put it back from the Trash in Finder.")
        }
    }

    private var title: Text {
        guard let file else { return Text("Move to Trash?") }
        return Text("Move “\(file.name)” to the Trash?")
    }
}
