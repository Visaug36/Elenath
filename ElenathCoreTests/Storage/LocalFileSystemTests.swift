import ElenathCore
import Foundation
import Testing

struct LocalFileSystemTests {
    private let fileSystem = LocalFileSystem()

    @Test func atomicWritesReplaceTheFileAndLeaveNoTemporaryFiles() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let file = folder.url.appending(component: "library.json", directoryHint: .notDirectory)

        try fileSystem.writeAtomically(Data("first".utf8), to: file)
        try fileSystem.writeAtomically(Data("second, longer".utf8), to: file)
        try fileSystem.writeAtomically(Data("third".utf8), to: file)

        let contents = try Data(contentsOf: file)
        #expect(contents == Data("third".utf8))
        #expect(TestFiles.names(in: folder.url) == ["library.json"])
    }

    @Test func readsWhatWasWritten() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let file = folder.url.appending(component: "notes.txt", directoryHint: .notDirectory)
        try fileSystem.writeAtomically(Data("hello".utf8), to: file)
        let data = try fileSystem.readData(at: file)
        #expect(data == Data("hello".utf8))
        #expect(throws: (any Error).self) {
            _ = try fileSystem.readData(at: folder.child("missing.txt"))
        }
    }

    @Test func existenceAndDirectories() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let directory = try folder.makeDirectory("Sub")
        let file = folder.url.appending(component: "file.txt", directoryHint: .notDirectory)
        try Data("x".utf8).write(to: file)
        let missing = folder.child("missing")

        #expect(fileSystem.fileExists(at: directory))
        #expect(fileSystem.isDirectory(at: directory))
        #expect(fileSystem.fileExists(at: file))
        #expect(!fileSystem.isDirectory(at: file))
        #expect(!fileSystem.fileExists(at: missing))
        #expect(!fileSystem.isDirectory(at: missing))
    }

    @Test func createDirectoryMakesParentsAndAcceptsExistingFolders() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let nested = folder.child("a/b/c")
        try fileSystem.createDirectory(at: nested)
        try fileSystem.createDirectory(at: nested)
        #expect(fileSystem.isDirectory(at: nested))
    }

    @Test func listingIncludesHiddenFiles() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        try Data("x".utf8).write(to: folder.url.appending(component: ".hidden", directoryHint: .notDirectory))
        try Data("x".utf8).write(to: folder.url.appending(component: "visible", directoryHint: .notDirectory))
        let contents = try fileSystem.contentsOfDirectory(at: folder.url)
        let names = Set(contents.map(\.lastPathComponent))
        #expect(names == [".hidden", "visible"])
    }

    @Test func copyMoveAndRemove() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let original = folder.url.appending(component: "original.txt", directoryHint: .notDirectory)
        let copy = folder.url.appending(component: "copy.txt", directoryHint: .notDirectory)
        let moved = folder.url.appending(component: "moved.txt", directoryHint: .notDirectory)
        try Data("content".utf8).write(to: original)

        try fileSystem.copyItem(at: original, to: copy)
        #expect(throws: (any Error).self) {
            try fileSystem.copyItem(at: original, to: copy)
        }
        try fileSystem.moveItem(at: copy, to: moved)
        #expect(TestFiles.names(in: folder.url) == ["original.txt", "moved.txt"])
        let movedData = try Data(contentsOf: moved)
        #expect(movedData == Data("content".utf8))

        try fileSystem.removeItem(at: moved)
        #expect(TestFiles.names(in: folder.url) == ["original.txt"])
    }

    @Test func modificationDateIsKnownOnlyForExistingItems() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let file = folder.url.appending(component: "file.txt", directoryHint: .notDirectory)
        try Data("x".utf8).write(to: file)
        #expect(fileSystem.modificationDate(at: file) != nil)
        #expect(fileSystem.modificationDate(at: folder.child("missing")) == nil)
    }
}
