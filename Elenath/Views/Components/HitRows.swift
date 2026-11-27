import ElenathCore
import SwiftUI

/// What search results and related notes show of a hit: its symbol, and its place line (docs/DESIGN.md,
/// "Search and Jump" and "The editor").
enum HitDisplay {
    /// A note's symbol, or the file type's, or the calendar's for a file in an event's folder.
    static func symbol(for item: SearchHit.Item) -> String {
        switch item {
        case .note: "doc.text"
        case .file(_, let path): fileSymbol(path.name)
        case .eventFile: "calendar"
        }
    }

    static func fileSymbol(_ name: String) -> String {
        switch FileTextKind(fileName: name) {
        case .pdf: "doc.richtext"
        case .picture: "photo"
        case .plainText: "doc.plaintext"
        case nil: "doc"
        }
    }
}

/// The place line of a hit: the space dot with the space and folder, or with the event's title and day for a
/// file in an event's folder, and the page of a PDF.
struct HitPlaceLabel: View {
    let hit: SearchHit
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            switch hit.item {
            case .note(let note):
                PlaceLabel(container: note.container, folder: note.path.folder)
            case .file(let container, let path):
                PlaceLabel(container: container, folder: path.folder)
            case .eventFile(let container, let event, _):
                HStack(spacing: 5) {
                    SpaceDot(space: model.space(of: container), size: 6)
                    if let label = model.eventLabel(of: event) {
                        Text("\(label.title) · \(label.day)")
                            .font(Typography.footnote)
                            .foregroundStyle(Color.textTertiary)
                            .lineLimit(1)
                    }
                }
            }
            if let page = hit.page {
                Text("Page \(page)")
                    .font(Typography.footnote)
                    .monospacedDigit()
                    .foregroundStyle(Color.textTertiary)
            }
        }
    }
}
