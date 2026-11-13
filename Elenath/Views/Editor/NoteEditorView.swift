import ElenathCore
import SwiftUI

/// An open note: a filing bar for an Inbox item, a banner when something needs saying, and the text.
struct NoteEditorView: View {
    let session: EditorSession
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if session.ref.container == .inbox, !session.isReadOnly {
                FilingBar(note: session.ref)
            }
            if let banner = session.banner {
                EditorBannerView(banner: banner, session: session)
            }
            MarkdownEditor(
                session: session, model: model, bodyGeneration: session.bodyGeneration,
                contentRevision: model.contentRevision, isReadOnly: session.isReadOnly, noteRef: session.ref)
        }
        .background(Color.backgroundWindow)
    }
}

/// Above an Inbox item: where to file it, or the Trash.
private struct FilingBar: View {
    let note: NoteRef
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray")
                .foregroundStyle(Color.textSecondary)
                .accessibilityHidden(true)
            Text("In your Inbox")
                .font(Typography.secondary)
                .foregroundStyle(Color.textSecondary)
            Spacer()
            MoveMenu(title: Text("File to…")) { container, folder in
                model.move(note, to: folder, in: container)
            }
            .menuStyle(.button)
            .buttonStyle(.borderedProminent)
            .tint(Color.accentColor)
            .fixedSize()
            Button("Move to Trash") {
                model.trash(note)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.backgroundSidebar)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.separatorLine)
                .frame(height: 1)
        }
    }
}

/// The slim strip above the text that says something about the note (docs/DESIGN.md, "Banners").
private struct EditorBannerView: View {
    let banner: EditorBanner
    let session: EditorSession
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(Color.accentText)
                .accessibilityHidden(true)
            message
                .font(Typography.secondary)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            buttons
                .font(Typography.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.backgroundSidebar)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.separatorLine)
                .frame(height: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var symbol: String {
        switch banner {
        case .readOnly, .notUTF8: "lock.fill"
        case .conflict, .saveFailed, .missing: "exclamationmark.triangle"
        }
    }

    private var message: Text {
        switch banner {
        case .readOnly:
            Text("Read-only: this was saved by a newer version of Elenath.")
        case .notUTF8:
            Text("Elenath can't edit this file's text encoding, so it is shown read-only.")
        case .conflict:
            Text("This note changed on disk while you were editing. Your version is saved as “\(session.ref.title)”.")
        case .saveFailed:
            Text("Elenath couldn't save this note. Your text is safe here, and Elenath keeps trying.")
        case .missing:
            Text("This note was moved or deleted outside Elenath.")
        }
    }

    @ViewBuilder private var buttons: some View {
        switch banner {
        case .conflict(let original):
            Button("Open the Other Version") {
                model.open(original)
            }
            Button("OK") {
                session.dismissBanner()
            }
        case .saveFailed:
            Button("Try Again") {
                session.retrySave()
            }
        case .missing:
            Button("Save It Again") {
                session.saveAgain()
            }
            Button("Close") {
                model.goBack()
            }
        case .readOnly, .notUTF8:
            EmptyView()
        }
    }
}
