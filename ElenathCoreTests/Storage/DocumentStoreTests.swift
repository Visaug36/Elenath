import ElenathCore
import Foundation
import Testing

/// The store that saves library.json and space.json: Ithil's LibraryStore with the document type taken out.
struct DocumentStoreTests {
    /// Tuesday 2026-11-10 14:30:00 UTC.
    private static let start = Date(timeIntervalSince1970: 1_794_321_000)

    private struct Fixture {
        let folder: TempFolder
        let owner: URL
        let safety: URL
        let clock: TestClock

        init() throws {
            folder = try TempFolder()
            owner = try folder.makeDirectory("Library")
            safety = folder.child("Safety")
            clock = TestClock(DocumentStoreTests.start)
        }

        var metadata: URL { owner.appending(component: ".elenath", directoryHint: .isDirectory) }
        var file: URL { metadata.appending(component: "library.json", directoryHint: .notDirectory) }
        var backups: URL { metadata.appending(component: "backups", directoryHint: .isDirectory) }
        var backupNames: [String] { TestFiles.names(in: backups).sorted() }

        func store(
            knownID: UUID? = nil, fileSystem: any FileSystem = LocalFileSystem(), backupInterval: TimeInterval = 3600,
            maxBackups: Int = 10
        ) -> DocumentStore<LibraryDocument> {
            DocumentStore(
                owner: owner, metadataFolderName: ".elenath", safetyDirectory: safety, knownDocumentID: knownID,
                fileSystem: fileSystem, timeSource: clock, backupInterval: backupInterval, maxBackups: maxBackups)
        }

        func safetyCopy(of document: LibraryDocument) -> URL {
            safety.appending(component: "\(document.documentID.uuidString).json", directoryHint: .notDirectory)
        }
    }

    private static func sample(spaces: Int = 2) -> LibraryDocument {
        LibraryDocument(
            id: LibraryID(UUID(uuidString: "5F0C1B7E-3A0D-4B0E-9C59-0F5B6E1D2A31")!),
            spaces: (0..<spaces).map { _ in SpaceID() },
            settings: ["later": .object(["kept": .bool(true), "count": .number(3)])])
    }

    private static func isUnreadable(_ error: (any Error)?) -> Bool {
        guard let storeError = error as? DocumentStoreError, case .unreadable = storeError else { return false }
        return true
    }

    // MARK: - Create, save and load

    @Test func createThenLoadRoundTrips() async throws {
        let fixture = try Fixture()
        defer { fixture.folder.remove() }
        let document = Self.sample()
        try await fixture.store().create(document)
        let loaded = try await fixture.store().load()
        #expect(loaded.document == document)
        #expect(loaded.recovery == nil)
    }

    @Test func theFileIsPrettyJSONWithSortedKeysAndItsSchemaVersion() async throws {
        let fixture = try Fixture()
        defer { fixture.folder.remove() }
        try await fixture.store().create(Self.sample())
        let text = try String(contentsOf: fixture.file, encoding: .utf8)
        #expect(text.contains("\n"))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["savedAt"] as? String == "2026-11-10T14:30:00Z")
        #expect(object["id"] as? String == "5F0C1B7E-3A0D-4B0E-9C59-0F5B6E1D2A31")
        let keys = ["\"id\"", "\"savedAt\"", "\"schemaVersion\"", "\"settings\"", "\"spaces\""]
        let positions = keys.compactMap { text.range(of: $0)?.lowerBound }
        #expect(positions.count == keys.count)
        #expect(positions == positions.sorted())
    }

    @Test func savesLeaveNoStrayFilesAndKeepTheSafetyCopyInStep() async throws {
        let fixture = try Fixture()
        defer { fixture.folder.remove() }
        let store = fixture.store()
        var document = Self.sample()
        try await store.create(document)
        for _ in 0..<3 {
            fixture.clock.advance(by: 60)
            document.spaces.append(SpaceID())
            try await store.save(document)
            let saved = try Data(contentsOf: fixture.file)
            let safetyCopy = try Data(contentsOf: fixture.safetyCopy(of: document))
            #expect(saved == safetyCopy)
        }
        #expect(TestFiles.names(in: fixture.metadata) == ["library.json", "backups"])
        #expect(TestFiles.names(in: fixture.owner) == [".elenath"])
    }

    @Test func createRefusesAnExistingDocumentAndAMissingFolder() async throws {
        let fixture = try Fixture()
        defer { fixture.folder.remove() }
        let first = Self.sample()
        try await fixture.store().create(first)
        await #expect(throws: (any Error).self) {
            try await fixture.store().create(LibraryDocument())
        }
        #expect(try await fixture.store().load().document == first)

        let gone = DocumentStore<LibraryDocument>(
            owner: fixture.folder.child("Gone"), metadataFolderName: ".elenath", safetyDirectory: fixture.safety,
            knownDocumentID: nil, fileSystem: LocalFileSystem(), timeSource: fixture.clock, backupInterval: 3600,
            maxBackups: 10)
        await #expect(throws: (any Error).self) {
            try await gone.create(Self.sample())
        }
        #expect(!TestFiles.exists(fixture.folder.child("Gone")))
    }

    // MARK: - Backups

    @Test func backupsAreMadeAtMostOncePerIntervalAndPruned() async throws {
        let fixture = try Fixture()
        defer { fixture.folder.remove() }
        let store = fixture.store(backupInterval: 3600, maxBackups: 2)
        var document = Self.sample()
        try await store.create(document)
        #expect(fixture.backupNames.isEmpty)

        fixture.clock.advance(by: 60)
        document.spaces.append(SpaceID())
        try await store.save(document)
        #expect(fixture.backupNames == ["library-20261110-143100.json"])

        // Within the hour: no second backup.
        fixture.clock.advance(by: 600)
        document.spaces.append(SpaceID())
        try await store.save(document)
        #expect(fixture.backupNames == ["library-20261110-143100.json"])

        // Two more hours apart: the oldest goes.
        for _ in 0..<2 {
            fixture.clock.advance(by: 3700)
            document.spaces.append(SpaceID())
            try await store.save(document)
        }
        #expect(fixture.backupNames.count == 2)
        #expect(!fixture.backupNames.contains("library-20261110-143100.json"))
    }

    @Test func otherFilesInTheBackupsFolderAreLeftAlone() async throws {
        let fixture = try Fixture()
        defer { fixture.folder.remove() }
        let store = fixture.store(backupInterval: 0, maxBackups: 1)
        var document = Self.sample()
        try await store.create(document)
        try FileManager.default.createDirectory(at: fixture.backups, withIntermediateDirectories: true)
        let stray = fixture.backups.appending(component: "notes.txt", directoryHint: .notDirectory)
        try Data("mine".utf8).write(to: stray)
        for _ in 0..<3 {
            fixture.clock.advance(by: 5)
            document.spaces.append(SpaceID())
            try await store.save(document)
        }
        #expect(TestFiles.exists(stray))
        #expect(fixture.backupNames.filter { $0.hasPrefix("library-") }.count == 1)
    }

    // MARK: - Recovery

    @Test func aDamagedFileIsRecoveredFromTheNewestBackupAndSetAside() async throws {
        let fixture = try Fixture()
        defer { fixture.folder.remove() }
        let store = fixture.store(backupInterval: 0)
        var document = Self.sample(spaces: 1)
        try await store.create(document)
        fixture.clock.advance(by: 60)
        document.spaces.append(SpaceID())
        let previous = document
        try await store.save(document)  // backs up the one-space version
        fixture.clock.advance(by: 60)
        document.spaces.append(SpaceID())
        try await store.save(document)  // backs up the two-space version
        // Lose the safety copy and damage the file: the newest backup holds the two-space version.
        try FileManager.default.removeItem(at: fixture.safety)
        try Data("{ not json".utf8).write(to: fixture.file)
        fixture.clock.advance(by: 60)

        let loaded = try await fixture.store().load()
        #expect(loaded.document == previous)
        let recovery = try #require(loaded.recovery)
        guard case .backup = recovery.source else {
            Issue.record("expected a backup, got \(recovery.source)")
            return
        }
        let aside = try #require(recovery.damagedFileMovedTo)
        #expect(aside.lastPathComponent == "library.corrupt-20261110-143300.json")
        #expect(try Data(contentsOf: aside) == Data("{ not json".utf8))
        // The recovered document is written back.
        #expect(try await fixture.store().load().recovery == nil)
    }

    @Test func aNewerSafetyCopyWinsOverTheBackups() async throws {
        let fixture = try Fixture()
        defer { fixture.folder.remove() }
        let store = fixture.store(backupInterval: 0)
        var document = Self.sample(spaces: 1)
        try await store.create(document)
        fixture.clock.advance(by: 60)
        document.spaces.append(SpaceID())
        try await store.save(document)
        try FileManager.default.removeItem(at: fixture.file)

        let loaded = try await fixture.store(knownID: document.documentID).load()
        #expect(loaded.document == document)
        guard case .safetyCopy = try #require(loaded.recovery).source else {
            Issue.record("expected the safety copy")
            return
        }
        #expect(loaded.recovery?.damagedFileMovedTo == nil)
    }

    @Test func undecodableBackupsAreSkipped() async throws {
        let fixture = try Fixture()
        defer { fixture.folder.remove() }
        let store = fixture.store(backupInterval: 0)
        var document = Self.sample(spaces: 1)
        let original = document
        try await store.create(document)
        fixture.clock.advance(by: 60)
        document.spaces.append(SpaceID())
        try await store.save(document)
        try FileManager.default.removeItem(at: fixture.safety)
        let broken = fixture.backups.appending(component: "library-20270101-000000.json", directoryHint: .notDirectory)
        try Data("garbage".utf8).write(to: broken)
        try Data("garbage".utf8).write(to: fixture.file)

        let loaded = try await fixture.store().load()
        #expect(loaded.document == original)
        #expect(TestFiles.exists(broken))
    }

    @Test func nothingToLoadIsMissingAndAMissingFolderIsNeverRecreated() async throws {
        let fixture = try Fixture()
        defer { fixture.folder.remove() }
        await #expect(throws: DocumentStoreError.missing) {
            try await fixture.store().load()
        }
        let goneOwner = fixture.folder.child("Gone")
        let gone = DocumentStore<LibraryDocument>(
            owner: goneOwner, metadataFolderName: ".elenath", safetyDirectory: fixture.safety,
            knownDocumentID: nil, fileSystem: LocalFileSystem(), timeSource: fixture.clock, backupInterval: 3600,
            maxBackups: 10)
        await #expect(throws: DocumentStoreError.missing) {
            try await gone.load()
        }
        await #expect(throws: (any Error).self) {
            try await gone.save(Self.sample())
        }
        #expect(!TestFiles.exists(goneOwner))
        #expect(!TestFiles.exists(fixture.safety))
    }

    @Test func aDamagedFileWithNothingToRecoverFromIsLeftInPlace() async throws {
        let fixture = try Fixture()
        defer { fixture.folder.remove() }
        try FileManager.default.createDirectory(at: fixture.metadata, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: fixture.file)
        var caught: (any Error)?
        do {
            _ = try await fixture.store().load()
        } catch {
            caught = error
        }
        #expect(Self.isUnreadable(caught))
        #expect(try Data(contentsOf: fixture.file) == Data("{ not json".utf8))
        #expect(TestFiles.names(in: fixture.metadata) == ["library.json"])
    }

    // MARK: - Newer schema

    @Test func aNewerSchemaOpensReadOnlyAndIsNeverOverwritten() async throws {
        let fixture = try Fixture()
        defer { fixture.folder.remove() }
        try FileManager.default.createDirectory(at: fixture.metadata, withIntermediateDirectories: true)
        let newer = Data(
            #"{"schemaVersion": 2, "id": "5F0C1B7E-3A0D-4B0E-9C59-0F5B6E1D2A31", "future": true}"#.utf8)
        try newer.write(to: fixture.file)

        let store = fixture.store()
        await #expect(throws: DocumentStoreError.newerSchema(found: 2, supported: 1)) {
            try await store.load()
        }
        await #expect(throws: DocumentStoreError.readOnly) {
            try await store.save(Self.sample())
        }
        // A store that never loaded checks before its first save, too.
        await #expect(throws: DocumentStoreError.readOnly) {
            try await fixture.store().save(Self.sample())
        }
        #expect(try Data(contentsOf: fixture.file) == newer)
        #expect(TestFiles.names(in: fixture.metadata) == ["library.json"])
    }

    @Test func aSaveAfterAFailedLoadSetsTheDamagedFileAside() async throws {
        let fixture = try Fixture()
        defer { fixture.folder.remove() }
        try FileManager.default.createDirectory(at: fixture.metadata, withIntermediateDirectories: true)
        try Data("damaged".utf8).write(to: fixture.file)
        let store = fixture.store()
        _ = try? await store.load()
        let document = Self.sample()
        try await store.save(document)
        #expect(try await fixture.store().load().document == document)
        let aside = TestFiles.names(in: fixture.metadata).filter { $0.hasPrefix("library.corrupt-") }
        #expect(aside.count == 1)
    }

    // MARK: - Failing disks

    @Test func aFailedWriteKeepsThePreviousFile() async throws {
        let fixture = try Fixture()
        defer { fixture.folder.remove() }
        let document = Self.sample()
        try await fixture.store().create(document)
        let before = try Data(contentsOf: fixture.file)

        let failing = fixture.store(fileSystem: FaultyFileSystem(failingWritesUnder: fixture.metadata))
        _ = try await failing.load()
        var changed = document
        changed.spaces.append(SpaceID())
        await #expect(throws: (any Error).self) {
            try await failing.save(changed)
        }
        #expect(try Data(contentsOf: fixture.file) == before)
    }

    @Test func aFailedSafetyCopyDoesNotFailTheSave() async throws {
        let fixture = try Fixture()
        defer { fixture.folder.remove() }
        let store = fixture.store(fileSystem: FaultyFileSystem(failingWritesUnder: fixture.safety))
        let document = Self.sample()
        try await store.create(document)
        #expect(try await fixture.store().load().document == document)
        #expect(!TestFiles.exists(fixture.safetyCopy(of: document)))
    }
}

struct DocumentCodecTests {
    @Test func savedAtIsRoundedToWholeSeconds() throws {
        let document = LibraryDocument()
        let data = try DocumentCodec.encode(document, savedAt: Date(timeIntervalSince1970: 1_794_321_000.6))
        let decoded = try DocumentCodec.decode(LibraryDocument.self, from: data)
        #expect(decoded.savedAt == Date(timeIntervalSince1970: 1_794_321_001))
        #expect(decoded.document == document)
        #expect(decoded.schemaVersion == 1)
    }

    @Test func unknownSettingsAreKept() throws {
        let json = #"""
            {"schemaVersion": 1, "id": "5F0C1B7E-3A0D-4B0E-9C59-0F5B6E1D2A31",
             "settings": {"future": {"list": [1, "two", null, false]}}}
            """#
        let decoded = try DocumentCodec.decode(LibraryDocument.self, from: Data(json.utf8))
        let expected: JSONValue = .object(["list": .array([.number(1), .string("two"), .null, .bool(false)])])
        #expect(decoded.document.settings["future"] == expected)
        #expect(decoded.document.spaces.isEmpty)
        let again = try DocumentCodec.decode(
            LibraryDocument.self, from: DocumentCodec.encode(decoded.document, savedAt: Date()))
        #expect(again.document == decoded.document)
    }

    @Test func aSpaceReadsItsSettingsAndFallsBackOnWhatItCannotRead() throws {
        let json = #"""
            {"schemaVersion": 1, "id": "0E6C3E2F-6F0B-4C55-9A1E-1D6A2B7C8D90", "color": "mauve",
             "sealed": true, "keywords": ["Uni", " lecture "]}
            """#
        let space = try DocumentCodec.decode(SpaceDocument.self, from: Data(json.utf8)).document
        #expect(space.sealed)
        #expect(space.color == .fallback)
        #expect(space.symbol == "folder")
        #expect(space.keywords == ["uni", "lecture"])
        #expect(space.description.isEmpty)
    }

    @Test func aSealedValueThatIsNotABooleanMakesTheFileDamaged() {
        // "sealed" must never be guessed: the space then counts as sealed until it is restored or decided.
        let json = #"{"schemaVersion": 1, "id": "0E6C3E2F-6F0B-4C55-9A1E-1D6A2B7C8D90", "sealed": "yes"}"#
        #expect(throws: DocumentStoreError.self) {
            try DocumentCodec.decode(SpaceDocument.self, from: Data(json.utf8))
        }
    }

    @Test func newerAndDamagedFilesAreRefused() {
        let newer = #"{"schemaVersion": 9, "id": "5F0C1B7E-3A0D-4B0E-9C59-0F5B6E1D2A31"}"#
        #expect(throws: DocumentStoreError.newerSchema(found: 9, supported: 1)) {
            try DocumentCodec.decode(LibraryDocument.self, from: Data(newer.utf8))
        }
        for damaged in ["", "[]", "{}", #"{"schemaVersion": "1"}"#, #"{"schemaVersion": 0}"#, #"{"schemaVersion": 1}"#]
        {
            #expect(throws: DocumentStoreError.self) {
                try DocumentCodec.decode(LibraryDocument.self, from: Data(damaged.utf8))
            }
        }
    }

    @Test func migrationsRunInOrderBeforeDecoding() throws {
        let migrator = SchemaMigrator(
            currentVersion: 3,
            steps: [
                1: { object in object["spaces"] = [] },
                2: { object in
                    var settings = object["settings"] as? [String: Any] ?? [:]
                    settings["migrated"] = true
                    object["settings"] = settings
                },
            ])
        let old = #"{"schemaVersion": 1, "id": "5F0C1B7E-3A0D-4B0E-9C59-0F5B6E1D2A31"}"#
        let decoded = try DocumentCodec.decode(LibraryDocument.self, from: Data(old.utf8), migrator: migrator)
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.document.settings["migrated"] == .bool(true))
        let missingStep = SchemaMigrator(currentVersion: 3, steps: [1: { _ in }])
        #expect(throws: DocumentStoreError.self) {
            try DocumentCodec.decode(LibraryDocument.self, from: Data(old.utf8), migrator: missingStep)
        }
    }
}
