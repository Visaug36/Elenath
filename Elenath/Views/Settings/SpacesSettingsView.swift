import ElenathCore
import SwiftUI

/// Spaces: the spaces in sidebar order, dragged to reorder, each with Edit… and Move to Trash, and New
/// Space….
struct SpacesSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var sheet: SpaceSheetRequest?
    @State private var selection: SpaceID?
    @State private var spaceToTrash: Space?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.state != .ready {
                Text("Open your library to change its spaces.")
                    .font(Typography.body)
                    .foregroundStyle(Color.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(model.spaces) { space in
                        SpaceSettingsRow(space: space)
                            .tag(space.id)
                            .contextMenu {
                                Button("Edit…") { sheet = .edit(space.id) }
                                Button("Move to Trash…") { spaceToTrash = space }
                            }
                    }
                    .onMove { source, destination in
                        model.moveSpaces(fromOffsets: source, toOffset: destination)
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: false))
                .frame(minHeight: 220)
                HStack(spacing: 8) {
                    Button("New Space…") {
                        sheet = .new
                    }
                    .disabled(!model.canEdit)
                    Spacer()
                    Button("Edit…") {
                        if let selection {
                            sheet = .edit(selection)
                        }
                    }
                    .disabled(selection == nil || !model.canEdit)
                    Button("Move to Trash…") {
                        spaceToTrash = selection.flatMap { model.space($0) }
                    }
                    .disabled(selection == nil || !model.canEdit)
                }
                Text("Drag spaces to change their order in the sidebar. A sealed space keeps its notes to itself.")
                    .font(Typography.footnote)
                    .foregroundStyle(Color.textTertiary)
            }
        }
        .padding(20)
        .frame(height: 380)
        .background(Color.backgroundWindow)
        .sheet(item: $sheet) { request in
            SpaceSheet(request: request)
        }
        .alert(
            "Move this space to the Trash?",
            isPresented: Binding(get: { spaceToTrash != nil }, set: { if !$0 { spaceToTrash = nil } }),
            presenting: spaceToTrash
        ) { space in
            Button("Move to Trash", role: .destructive) {
                model.trashSpace(space.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { space in
            Text(
                "The folder “\(space.name)” and everything in it go to the Trash. You can put it back from there, or with Edit › Undo."
            )
        }
    }
}

private struct SpaceSettingsRow: View {
    let space: Space

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: SpaceStyle.symbol(for: space))
                .foregroundStyle(SpaceStyle.color(for: space))
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(verbatim: space.name)
                .font(Typography.body)
            if space.isSealed {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.textTertiary)
                    .accessibilityLabel(Text("Sealed"))
            }
            Spacer()
            if !space.keywords.isEmpty {
                Text(verbatim: space.keywords.joined(separator: ", "))
                    .font(Typography.footnote)
                    .foregroundStyle(Color.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}
