import Foundation

/// The hidden file in every event folder that says which occurrence the folder belongs to, so Ithil finds
/// the folder even after it was renamed or moved to another day folder in Finder.
///
/// ```json
/// { "date" : "2026-10-06", "eventID" : "…", "version" : 1 }
/// ```
///
/// `date` is the occurrence's `Occurrence.date` (the series key), so each occurrence of a repeating event
/// has its own marker.
public struct EventFolderMarker: Codable, Hashable, Sendable {
    /// The marker's file name inside an event folder.
    public static let fileName = ".ithil-event"

    public var eventID: UUID
    public var date: CalendarDate
    /// The marker format. Always 1 so far.
    public var version: Int

    public init(eventID: UUID, date: CalendarDate) {
        self.eventID = eventID
        self.date = date
        self.version = Self.currentVersion
    }

    private enum CodingKeys: String, CodingKey {
        case eventID, date, version
    }

    /// `version` may be missing (it then reads as 1); unknown keys are ignored.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.eventID = try container.decode(UUID.self, forKey: .eventID)
        self.date = try container.decode(CalendarDate.self, forKey: .date)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
    }
}

extension EventFolderMarker {
    /// The format this version of Ithil writes.
    static let currentVersion = 1

    /// The marker for an occurrence's folder.
    init(occurrence: Occurrence) {
        self.init(eventID: occurrence.event.id, date: occurrence.date)
    }

    /// The most of a marker file that is read. A real one is about 100 bytes; a larger file isn't a marker.
    static let maximumByteCount = 64 * 1024

    /// Reads a marker file's contents. Nil when it isn't a marker.
    init?(markerFileData data: Data) {
        guard data.count < Self.maximumByteCount, DocumentCodec.isSafeToParse(data),
            let marker = try? JSONDecoder().decode(EventFolderMarker.self, from: data)
        else { return nil }
        self = marker
    }

    /// The marker in `folder`, read without following a link and without reading more than
    /// `maximumByteCount` bytes. Nil when there is none or it isn't a marker.
    static func read(in folder: URL, fileSystem: any FileSystem) -> EventFolderMarker? {
        let file = folder.appending(component: fileName, directoryHint: .notDirectory)
        guard let info = fileSystem.info(at: file), !info.isDirectory, !info.isSymbolicLink, !info.isSpecial,
            let data = try? fileSystem.readData(at: file, upTo: maximumByteCount)
        else { return nil }
        return EventFolderMarker(markerFileData: data)
    }

    /// The occurrence this marker names.
    var occurrenceID: Occurrence.ID {
        Occurrence.ID(eventID: eventID, date: date)
    }

    /// The marker file's contents: small, pretty-printed JSON with sorted keys.
    func markerFileData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
