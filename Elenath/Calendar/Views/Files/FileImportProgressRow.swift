import ElenathCore
import SwiftUI

/// A slim amber progress bar under "Copying 2 of 3…", with a button that stops the copy. Items already
/// copied stay in the event's folder.
struct FileImportProgressRow: View {
    let progress: FileCopyProgress
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(FileLabels.copying(progress))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                ProgressView(value: progress.fractionCompleted)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .tint(Color.accentColor)
                    .accessibilityLabel(Text(FileLabels.copying(progress)))
            }
            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.textTertiary)
            }
            .buttonStyle(.borderless)
            .help("Stop Copying")
            .accessibilityLabel(Text("Stop Copying"))
        }
        .accessibilityElement(children: .contain)
    }
}
