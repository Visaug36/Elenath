import Foundation

/// What happens when a link or a file in a note is opened (docs/ARCHITECTURE.md, "Opening links and
/// files").
///
/// Web pages and e-mail addresses open at once, and so do documents, pictures, sound and video. Anything
/// else is asked about first: a link that opens another app, or a file that could be a program (an app, a
/// script, an installer, a link file that leads somewhere else), because opening it could run something.
public enum OpenPolicy {
    public enum Decision: Hashable, Sendable {
        /// Open it in the app the Mac uses for it.
        case open
        /// Ask first, saying what it is.
        case ask
    }

    /// The schemes that open without asking: the web and e-mail.
    public static let schemesOpenedAtOnce: Set<String> = ["http", "https", "mailto"]

    /// File extensions that open without asking: documents, pictures, sound and video. Everything else is
    /// asked about, unknown kinds included.
    public static let extensionsOpenedAtOnce: Set<String> = [
        // Pictures
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "avif", "dng",
        // Documents
        "pdf", "txt", "md", "markdown", "rtf", "csv", "tsv", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
        "odt", "ods", "odp", "pages", "numbers", "key", "epub",
        // Sound and video
        "mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "ogg", "opus", "mp4", "m4v", "mov", "avi", "mkv",
        "webm",
    ]

    /// For a link written in a note: its scheme decides. A link without one isn't opened as a link.
    public static func decision(forLink address: String) -> Decision {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespaces)),
            let scheme = url.scheme?.lowercased(), schemesOpenedAtOnce.contains(scheme)
        else { return .ask }
        return .open
    }

    /// For a file of the library: its extension decides.
    public static func decision(forFileNamed name: String) -> Decision {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count > 1, let last = parts.last else { return .ask }
        return extensionsOpenedAtOnce.contains(last.lowercased()) ? .open : .ask
    }
}
