import Foundation

/// Reads and writes Elenath's JSON documents: a versioned envelope around the document's own keys.
///
/// ```json
/// { "schemaVersion": 1, "savedAt": "2026-11-10T14:30:00Z", "id": "…", … }
/// ```
///
/// Files are pretty-printed with sorted keys, so they diff cleanly and stay readable in a text editor.
public enum DocumentCodec {
    /// The document as file bytes, stamped with its current schema version and `savedAt` (rounded to whole
    /// seconds).
    public static func encode<Document: VersionedDocument>(_ document: Document, savedAt: Date) throws -> Data {
        let envelope = DocumentWriteEnvelope(
            schemaVersion: Document.currentSchemaVersion, savedAt: savedAt.roundedToSecond, document: document)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(envelope)
    }

    /// Decodes a document, migrating older schemas in memory.
    ///
    /// Throws `DocumentStoreError.newerSchema` for a file written by a newer Elenath and
    /// `DocumentStoreError.unreadable` for anything else that can't be decoded.
    public static func decode<Document: VersionedDocument>(
        _ type: Document.Type, from data: Data
    ) throws -> DecodedDocument<Document> {
        try decode(type, from: data, migrator: Document.migrator)
    }

    /// Decodes with a specific set of migrations; `migrator.currentVersion` is the newest schema
    /// accepted. Tests inject their own.
    public static func decode<Document: VersionedDocument>(
        _ type: Document.Type, from data: Data, migrator: SchemaMigrator
    ) throws -> DecodedDocument<Document> {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw DocumentStoreError.unreadable("Not valid JSON: \(error.localizedDescription)")
        }
        guard var object = parsed as? [String: Any] else {
            throw DocumentStoreError.unreadable("The top level is not a JSON object")
        }

        let foundVersion: Int
        do {
            foundVersion = try migrator.migrate(&object)
        } catch let error as DocumentStoreError {
            throw error
        } catch {
            throw DocumentStoreError.unreadable("Migration failed: \(String(describing: error))")
        }

        // Unchanged files are decoded from the original bytes; migrated ones are re-serialized first.
        var json = data
        if foundVersion != migrator.currentVersion {
            guard JSONSerialization.isValidJSONObject(object) else {
                throw DocumentStoreError.unreadable("A migration produced a value JSON can't hold")
            }
            do {
                json = try JSONSerialization.data(withJSONObject: object, options: [])
            } catch {
                throw DocumentStoreError.unreadable("Migration output: \(error.localizedDescription)")
            }
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let envelope = try decoder.decode(DocumentReadEnvelope<Document>.self, from: json)
            return DecodedDocument(
                document: envelope.document, savedAt: envelope.savedAt, schemaVersion: foundVersion)
        } catch {
            throw DocumentStoreError.unreadable("Not a valid document: \(String(describing: error))")
        }
    }
}

/// The result of decoding a document.
public struct DecodedDocument<Document: VersionedDocument>: Hashable, Sendable {
    public var document: Document
    /// When the file was written, if it says.
    public var savedAt: Date?
    /// The schema version the file was written with, before any migration.
    public var schemaVersion: Int

    public init(document: Document, savedAt: Date?, schemaVersion: Int) {
        self.document = document
        self.savedAt = savedAt
        self.schemaVersion = schemaVersion
    }
}

/// Brings an document written with an older schema up to `currentVersion`, one version at
/// a time, before it is decoded.
///
/// Steps work on the raw JSON object (`[String: Any]` from `JSONSerialization`); step `n` turns
/// version `n` into `n + 1`, and the migrator updates `schemaVersion` after each one. Migration happens
/// in memory only: the file is rewritten in the current schema at the next save.
public struct SchemaMigrator: Sendable {
    public typealias Step = @Sendable (inout [String: Any]) throws -> Void

    /// The newest schema version; files with a higher one are refused as `newerSchema`.
    public let currentVersion: Int
    private let steps: [Int: Step]

    public init(currentVersion: Int, steps: [Int: Step]) {
        self.currentVersion = currentVersion
        self.steps = steps
    }

    /// Runs every step from the object's `schemaVersion` up to `currentVersion`, in order.
    ///
    /// Returns the version the object started at. Throws `DocumentStoreError.unreadable` if
    /// `schemaVersion` is missing, not a whole number or below 1, or a step is missing;
    /// `DocumentStoreError.newerSchema` if it is above `currentVersion`; and rethrows a failing step's
    /// error.
    @discardableResult
    public func migrate(_ object: inout [String: Any]) throws -> Int {
        guard let foundVersion = object[Self.versionKey] as? Int else {
            throw DocumentStoreError.unreadable("schemaVersion is missing or not a whole number")
        }
        guard foundVersion >= 1 else {
            throw DocumentStoreError.unreadable("Unsupported schemaVersion \(foundVersion)")
        }
        guard foundVersion <= currentVersion else {
            throw DocumentStoreError.newerSchema(found: foundVersion, supported: currentVersion)
        }
        var version = foundVersion
        while version < currentVersion {
            guard let step = steps[version] else {
                throw DocumentStoreError.unreadable("No migration from schemaVersion \(version)")
            }
            try step(&object)
            version += 1
            object[Self.versionKey] = version
        }
        return foundVersion
    }

    static let versionKey = "schemaVersion"
}

/// What `DocumentCodec.encode` writes: the document's own keys plus the envelope's. Keys are sorted on
/// output.
private struct DocumentWriteEnvelope<Document: VersionedDocument>: Encodable {
    var schemaVersion: Int
    var savedAt: Date
    var document: Document

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, savedAt
    }

    func encode(to encoder: Encoder) throws {
        try document.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(savedAt, forKey: .savedAt)
    }
}

/// What `DocumentCodec.decode` reads: the document itself plus the save time. `schemaVersion` has been
/// handled by then.
private struct DocumentReadEnvelope<Document: VersionedDocument>: Decodable {
    var savedAt: Date?
    var document: Document

    private enum CodingKeys: String, CodingKey {
        case savedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A damaged timestamp shouldn't cost the user their settings: treat it as unknown.
        savedAt = try? container.decodeIfPresent(Date.self, forKey: .savedAt)
        document = try Document(from: decoder)
    }
}

extension Date {
    /// This instant without its fraction of a second, the precision documents keep.
    var roundedToSecond: Date {
        Date(timeIntervalSince1970: timeIntervalSince1970.rounded())
    }
}
