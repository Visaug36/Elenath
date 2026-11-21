import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What a drag of files over a drop target looks like right now.
struct FileDragState: Equatable {
    /// Files are being dragged over the target, and it would take them.
    var isTargeted = false
    /// How many items are being dragged; 0 when macOS doesn't say.
    var itemCount = 0
}

extension View {
    /// Takes files and folders dragged from Finder (or any app that drags file URLs) and hands their URLs
    /// to `perform`, in the order they were dragged. Only the URLs are read here: copying is up to
    /// `perform`, and the originals are never touched.
    ///
    /// `state` follows the drag while it is over the view, so the view can show its drop state. When
    /// `isEnabled` is false (a read-only calendar) drags are refused.
    func fileDropTarget(
        isEnabled: Bool,
        state: Binding<FileDragState>,
        perform: @escaping @MainActor ([URL]) -> Void
    ) -> some View {
        onDrop(of: [.fileURL], delegate: FileDropDelegate(isEnabled: isEnabled, state: state, perform: perform))
    }
}

/// Follows a file drag over a view and collects the dropped URLs. (`DropDelegate` is main-actor isolated,
/// so this is too.)
private struct FileDropDelegate: DropDelegate {
    let isEnabled: Bool
    let state: Binding<FileDragState>
    let perform: @MainActor ([URL]) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        isEnabled && info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        let count = info.itemProviders(for: [.fileURL]).count
        state.wrappedValue = FileDragState(isTargeted: true, itemCount: count)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        state.wrappedValue = FileDragState()
    }

    func performDrop(info: DropInfo) -> Bool {
        state.wrappedValue = FileDragState()
        let providers = info.itemProviders(for: [.fileURL])
        guard isEnabled, !providers.isEmpty else { return false }
        let collector = DroppedFileURLs(count: providers.count, completion: perform)
        for (index, provider) in providers.enumerated() {
            DroppedFileLoading.load(provider, index: index, into: collector)
        }
        return true
    }
}

/// Reads the URL out of one dropped item. Not isolated to the main actor, so the item provider's
/// callback (which runs on a background thread) never inherits main-actor isolation.
private enum DroppedFileLoading {
    static func load(_ provider: NSItemProvider, index: Int, into collector: DroppedFileURLs) {
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            Task { @MainActor in
                collector.receive(url, at: index)
            }
        }
    }
}

/// Gathers the URLs of one drop as their item providers deliver them (in any order, off the main thread),
/// then hands the file URLs to `completion` once, in the order they were dragged.
@MainActor
private final class DroppedFileURLs {
    private var urls: [URL?]
    private var remaining: Int
    private let completion: @MainActor ([URL]) -> Void

    init(count: Int, completion: @escaping @MainActor ([URL]) -> Void) {
        urls = Array(repeating: nil, count: count)
        remaining = count
        self.completion = completion
    }

    func receive(_ url: URL?, at index: Int) {
        guard urls.indices.contains(index), remaining > 0 else { return }
        urls[index] = url
        remaining -= 1
        guard remaining == 0 else { return }
        let fileURLs = urls.compactMap { $0 }.filter(\.isFileURL)
        if !fileURLs.isEmpty {
            completion(fileURLs)
        }
    }
}

/// The amber ring and soft inner glow around a whole popover while files are dragged over it (DESIGN.md:
/// 1.5 pt ring, 32 pt glow at 32 %). The glow is drawn inward, since a popover clips anything outside it.
struct FileDropGlow: View {
    var cornerRadius: CGFloat = Metrics.Radius.popover

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let glow = Color.accentColor.opacity(Metrics.Glow.dropShadowOpacity)
        ZStack {
            shape
                .strokeBorder(glow, lineWidth: Metrics.Glow.dropShadowRadius / 2)
                .blur(radius: Metrics.Glow.dropShadowRadius / 2)
            shape
                .strokeBorder(Color.accentColor, lineWidth: Metrics.Glow.dropRing)
        }
        .clipShape(shape)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The dashed amber zone shown while files are dragged over the details popover: a folder, "Drop to add 2
/// files" and "Copied into 14.00 Physics Lecture".
struct FileDropPrompt: View {
    let itemCount: Int
    let folderName: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.Radius.dropZone, style: .continuous)
        VStack(spacing: 4) {
            Image(systemName: "folder")
                .font(.system(size: 20))
                .foregroundStyle(Color.accentText)
                .accessibilityHidden(true)
            Text(FileLabels.dropPrompt(itemCount: itemCount))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
            Text(FileLabels.copiedInto(folderName))
                .font(.system(size: 12))
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background {
            shape.fill(Color.accentSoft)
        }
        .overlay {
            shape.strokeBorder(Color.accentColor, style: FileDropZoneStyle.dash(lineWidth: Metrics.Glow.dropRing))
        }
        .accessibilityElement(children: .combine)
    }
}

/// The dashed border every drop zone uses.
@MainActor
enum FileDropZoneStyle {
    static func dash(lineWidth: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: lineWidth, dash: [5, 4])
    }

    /// The border of a drop zone nothing is dragged over: faint, or `TextSecondary` with Increase Contrast.
    static func idleBorder(contrast: ColorSchemeContrast) -> Color {
        contrast == .increased ? Color.textSecondary : Color.textTertiary.opacity(0.5)
    }
}
