import Foundation

/// How big a note Elenath works with (docs/ARCHITECTURE.md, "Limits"). A note can be any size on disk;
/// past these sizes Elenath does less with it rather than stall or run out of memory.
public enum NoteLimits {
    /// A note larger than this isn't opened in the editor: reading and laying out that much text would
    /// stall the app. It stays in its folder, found by its beginning, and opens in another app.
    public static let maximumOpenedBytes: Int64 = 16 * 1024 * 1024
    /// The editor styles a note up to this size as Markdown. A larger one is shown as plain text, so
    /// typing stays quick.
    public static let maximumStyledBytes = 2 * 1024 * 1024
    /// How much of a note the index reads: search finds what is in its first megabytes.
    public static let maximumIndexedBytes = 4 * 1024 * 1024
    /// A Markdown or text file larger than this is imported as a file, not as a note.
    public static let maximumImportedNoteBytes = maximumOpenedBytes
    /// A document (Word, RTF, a web page) larger than this is imported as a file, without its text.
    public static let maximumConvertedDocumentBytes: Int64 = 64 * 1024 * 1024

    /// `data` without a character cut in half at its end, for the first bytes of a longer file.
    public static func droppingSplitCharacter(_ data: Data) -> Data {
        var index = data.endIndex
        var continuationBytes = 0
        while index > data.startIndex, continuationBytes < 4 {
            index -= 1
            let byte = data[index]
            if byte & 0xC0 == 0x80 {
                continuationBytes += 1
                continue
            }
            let length = byte < 0x80 ? 1 : byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
            return continuationBytes + 1 < length ? data[data.startIndex..<index] : data
        }
        return data
    }
}
