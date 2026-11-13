import ElenathCore
import SwiftUI

/// At the foot of the window when notes were renamed or moved outside Elenath and other notes still link
/// to where they were: Update Links (amber, one undoable step) or Not Now.
struct LinkRepairBanner: View {
    @Environment(AppModel.self) private var model
    let offer: LinkRepairOffer

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "link")
                .foregroundStyle(Color.textSecondary)
                .accessibilityHidden(true)
            message
                .font(Typography.secondary)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Not Now") {
                model.dismissLinkRepair()
            }
            .buttonStyle(.plain)
            .font(Typography.secondary)
            .foregroundStyle(Color.textSecondary)
            Button("Update Links") {
                model.acceptLinkRepair()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!model.canEdit)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(Color.backgroundSidebar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.separatorLine)
                .frame(height: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var message: Text {
        let count = offer.linking.count
        guard offer.moves.count == 1, let move = offer.moves.first else {
            return Text(
                "\(offer.moves.count) notes were renamed or moved outside Elenath. Links in ^[\(count) note](inflect: true) still point to where they were."
            )
        }
        if move.from.path.folder == move.to.path.folder, move.from.container == move.to.container {
            return Text(
                "“\(move.from.title)” was renamed “\(move.to.title)” outside Elenath. Links in ^[\(count) note](inflect: true) still use the old name."
            )
        }
        return Text(
            "“\(move.from.title)” was moved outside Elenath. Links in ^[\(count) note](inflect: true) still point to where it was."
        )
    }
}
