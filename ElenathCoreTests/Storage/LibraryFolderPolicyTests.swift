import ElenathCore
import Foundation
import Testing

struct LibraryFolderPolicyTests {
    private let fileSystem = LocalFileSystem()

    private func makeFile(_ name: String, in folder: URL) throws {
        try Data("x".utf8).write(to: folder.appending(component: name, directoryHint: .notDirectory))
    }

    private func makeElenathFolder(at folder: URL) throws {
        let metadata = folder.appending(component: ".elenath", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true, attributes: nil)
        try makeFile("library.json", in: metadata)
    }

    @Test func defaultFolderNameIsElenath() {
        #expect(LibraryFolderPolicy.defaultFolderName == "Elenath")
    }

    @Test func emptyFolderIsUsedAsIs() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let chosen = try folder.makeDirectory("Chosen")

        #expect(LibraryFolderPolicy.isEffectivelyEmpty(chosen, fileSystem: fileSystem))
        #expect(!LibraryFolderPolicy.isLibrary(chosen, fileSystem: fileSystem))
        let result = try LibraryFolderPolicy.libraryFolder(forChosen: chosen, fileSystem: fileSystem)
        #expect(result.path == chosen.path)
        #expect(TestFiles.names(in: chosen).isEmpty)
    }

    @Test func finderMetadataDoesNotCount() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let chosen = try folder.makeDirectory("Chosen")
        try makeFile(".DS_Store", in: chosen)
        try makeFile(".localized", in: chosen)
        try makeFile("Icon\r", in: chosen)

        #expect(LibraryFolderPolicy.isEffectivelyEmpty(chosen, fileSystem: fileSystem))
        let result = try LibraryFolderPolicy.libraryFolder(forChosen: chosen, fileSystem: fileSystem)
        #expect(result.path == chosen.path)
        #expect(TestFiles.names(in: chosen) == [".DS_Store", ".localized", "Icon\r"])
    }

    @Test func onlyDSStoreIsEmpty() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let chosen = try folder.makeDirectory("Chosen")
        try makeFile(".DS_Store", in: chosen)

        let result = try LibraryFolderPolicy.libraryFolder(forChosen: chosen, fileSystem: fileSystem)
        #expect(result.path == chosen.path)
    }

    @Test func hiddenUserFilesDoCount() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let chosen = try folder.makeDirectory("Chosen")
        try makeFile(".zshrc", in: chosen)
        #expect(!LibraryFolderPolicy.isEffectivelyEmpty(chosen, fileSystem: fileSystem))
    }

    @Test func missingFoldersAndFilesAreNotEmpty() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        try makeFile("notes.txt", in: folder.url)
        #expect(!LibraryFolderPolicy.isEffectivelyEmpty(folder.child("Missing"), fileSystem: fileSystem))
        #expect(!LibraryFolderPolicy.isEffectivelyEmpty(folder.child("notes.txt"), fileSystem: fileSystem))
    }

    @Test func existingElenathFolderIsUsedAsIs() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let chosen = try folder.makeDirectory("Chosen")
        try makeElenathFolder(at: chosen)
        _ = try folder.makeDirectory("Chosen/2026-10-06")
        let before = TestFiles.names(in: chosen)

        #expect(LibraryFolderPolicy.isLibrary(chosen, fileSystem: fileSystem))
        let result = try LibraryFolderPolicy.libraryFolder(forChosen: chosen, fileSystem: fileSystem)
        #expect(result.path == chosen.path)
        #expect(TestFiles.names(in: chosen) == before)
    }

    @Test func aLibraryWithoutLibraryJSONStillCounts() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let chosen = try folder.makeDirectory("Chosen")
        _ = try folder.makeDirectory("Chosen/.elenath/backups")
        try makeFile("notes.txt", in: chosen)

        #expect(LibraryFolderPolicy.isLibrary(chosen, fileSystem: fileSystem))
        let result = try LibraryFolderPolicy.libraryFolder(forChosen: chosen, fileSystem: fileSystem)
        #expect(result.path == chosen.path)
    }

    @Test func otherFolderGetsAnElenathSubfolder() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let chosen = try folder.makeDirectory("Documents")
        try makeFile("notes.txt", in: chosen)

        #expect(!LibraryFolderPolicy.isEffectivelyEmpty(chosen, fileSystem: fileSystem))
        #expect(!LibraryFolderPolicy.isLibrary(chosen, fileSystem: fileSystem))
        let result = try LibraryFolderPolicy.libraryFolder(forChosen: chosen, fileSystem: fileSystem)
        #expect(result.path == chosen.appending(component: "Elenath").path)
        #expect(fileSystem.isDirectory(at: result))
        #expect(TestFiles.names(in: result).isEmpty)
        #expect(TestFiles.names(in: chosen) == ["notes.txt", "Elenath"])
    }

    @Test func emptyElenathSubfolderIsReused() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let chosen = try folder.makeDirectory("Documents")
        try makeFile("notes.txt", in: chosen)
        let existing = try folder.makeDirectory("Documents/Elenath")
        try makeFile(".DS_Store", in: existing)

        let result = try LibraryFolderPolicy.libraryFolder(forChosen: chosen, fileSystem: fileSystem)
        #expect(result.path == existing.path)
        #expect(TestFiles.names(in: chosen) == ["notes.txt", "Elenath"])
    }

    @Test func anExistingLibrarySubfolderIsReused() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let chosen = try folder.makeDirectory("Documents")
        try makeFile("notes.txt", in: chosen)
        let existing = try folder.makeDirectory("Documents/Elenath")
        try makeElenathFolder(at: existing)

        let result = try LibraryFolderPolicy.libraryFolder(forChosen: chosen, fileSystem: fileSystem)
        #expect(result.path == existing.path)
    }

    @Test func takenElenathNameMovesOnToElenath2() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let chosen = try folder.makeDirectory("Documents")
        try makeFile("notes.txt", in: chosen)
        let taken = try folder.makeDirectory("Documents/Elenath")
        try makeFile("homework.pdf", in: taken)

        let result = try LibraryFolderPolicy.libraryFolder(forChosen: chosen, fileSystem: fileSystem)
        #expect(result.lastPathComponent == "Elenath 2")
        #expect(result.path == chosen.appending(component: "Elenath 2").path)
        #expect(fileSystem.isDirectory(at: result))
        #expect(TestFiles.names(in: chosen) == ["notes.txt", "Elenath", "Elenath 2"])
        #expect(TestFiles.names(in: taken) == ["homework.pdf"])
    }

    @Test func fileNamedElenathIsSkippedToo() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let chosen = try folder.makeDirectory("Documents")
        try makeFile("Elenath", in: chosen)
        let taken = try folder.makeDirectory("Documents/Elenath 2")
        try makeFile("homework.pdf", in: taken)

        let result = try LibraryFolderPolicy.libraryFolder(forChosen: chosen, fileSystem: fileSystem)
        #expect(result.lastPathComponent == "Elenath 3")
        #expect(TestFiles.names(in: chosen) == ["Elenath", "Elenath 2", "Elenath 3"])
    }

    @Test func missingChosenFolderThrowsAndCreatesNothing() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let missing = folder.child("Missing")
        #expect(throws: (any Error).self) {
            _ = try LibraryFolderPolicy.libraryFolder(forChosen: missing, fileSystem: fileSystem)
        }
        #expect(!TestFiles.exists(missing))
    }
}
