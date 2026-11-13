import ElenathCore
import SwiftUI
import UniformTypeIdentifiers

/// Reads what was dragged onto a place in the library.
@MainActor
enum DroppedFiles {
    /// The file URLs in a drop, in order.
    static func urls(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            let url = await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    continuation.resume(returning: url)
                }
            }
            if let url, url.isFileURL {
                urls.append(url)
            }
        }
        return urls
    }
}

/// Makes a view a place things can be dropped on: files from Finder are imported there, notes and files
/// of the library are moved there. While something hovers, the view gets the drop glow.
struct LibraryDropTarget: ViewModifier {
    let container: Container
    let folder: ItemPath
    var cornerRadius: CGFloat = Metrics.Radius.listRow
    @Environment(AppModel.self) private var model
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: Metrics.Glow.dropRing)
                        .shadow(color: Color.accentColor.opacity(Metrics.Glow.dropShadowOpacity), radius: 8)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
                guard model.canEdit(container) else { return false }
                Task {
                    let urls = await DroppedFiles.urls(from: providers)
                    model.handleDropped(urls, into: container, folder: folder)
                }
                return true
            }
    }
}

extension View {
    /// Accepts dropped files and library items for a folder of a space or of the Inbox.
    func libraryDropTarget(_ container: Container, _ folder: ItemPath = .root, cornerRadius: CGFloat = 7) -> some View {
        modifier(LibraryDropTarget(container: container, folder: folder, cornerRadius: cornerRadius))
    }
}
