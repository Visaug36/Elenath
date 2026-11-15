import AppKit
import ElenathCore
import Foundation

/// What choosing another folder in Settings › Files means, worked out before anything is moved (from
/// Ithil's `LibraryFolderChoice`).
enum LibraryFolderChoice: Equatable, Sendable {
    /// The chosen folder is (or holds, as `Elenath`) the library that is open now.
    case currentLibrary
    /// The chosen folder is inside the open library's folder.
    case insideCurrentLibrary
    /// The chosen folder is (or holds, as `Elenath`) another library, which can be opened instead.
    case otherLibrary(URL)
    /// The library can move there: into the chosen folder itself when it is empty, otherwise into a new or
    /// empty `Elenath` (`Elenath 2`…) folder inside it.
    case move(chosen: URL, newRoot: URL)
    /// The chosen folder can't be used.
    case unavailable

    /// Decides what choosing `chosen` means while the library in `currentRoot` is open. Reads the disk and
    /// writes nothing: call it off the main actor.
    static func evaluate(_ chosen: URL, currentRoot: URL) -> LibraryFolderChoice {
        let fileSystem = LocalFileSystem()
        guard fileSystem.isDirectory(at: chosen) else { return .unavailable }
        if isSameFolder(chosen, currentRoot) {
            return .currentLibrary
        }
        if PathContainment.contains(chosen, in: currentRoot) {
            return .insideCurrentLibrary
        }
        if LibraryFolderPolicy.isLibrary(chosen, fileSystem: fileSystem) {
            return .otherLibrary(chosen)
        }
        if LibraryFolderPolicy.isEffectivelyEmpty(chosen, fileSystem: fileSystem) {
            return .move(chosen: chosen, newRoot: chosen)
        }
        let baseName = LibraryFolderPolicy.defaultFolderName
        for number in 1...999 {
            let name = number == 1 ? baseName : "\(baseName) \(number)"
            let candidate = chosen.appending(component: name, directoryHint: .isDirectory)
            if !fileSystem.fileExists(at: candidate) {
                return .move(chosen: chosen, newRoot: candidate)
            }
            if LibraryFolderPolicy.isLibrary(candidate, fileSystem: fileSystem) {
                return isSameFolder(candidate, currentRoot) ? .currentLibrary : .otherLibrary(candidate)
            }
            if LibraryFolderPolicy.isEffectivelyEmpty(candidate, fileSystem: fileSystem) {
                return .move(chosen: chosen, newRoot: candidate)
            }
        }
        return .unavailable
    }

    private static func isSameFolder(_ first: URL, _ second: URL) -> Bool {
        first.standardizedFileURL.resolvingSymlinksInPath().path
            == second.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

enum LibraryMoveError: Error, LocalizedError {
    case notReady
    case stillSaving
    case folderChanged
    case importRunning
    /// Something tried to write while the library moves.
    case moving

    var errorDescription: String? {
        switch self {
        case .moving: String(localized: "Elenath is moving your library. Try again in a moment; your text is kept.")
        case .notReady: String(localized: "The library can't be moved right now.")
        case .stillSaving: String(localized: "A note is still being saved. Try again in a moment.")
        case .folderChanged: String(localized: "The folder changed while Elenath looked at it. Choose it again.")
        case .importRunning: String(localized: "Wait until the import has finished, then try again.")
        }
    }
}

/// Changing the library's folder (Settings › Files).
extension AppModel {
    /// Moves the library into the folder `chosen` stands for, and opens it there. The move goes back
    /// entirely if one item can't move.
    ///
    /// Nothing writes into the library while it moves: the open note is closed and saved first, nothing
    /// can be edited, captured or imported (`canEdit` is false), and the folder watcher is paused, so
    /// files leaving don't look like changes to react to.
    func moveLibrary(toChosen chosen: URL) async throws {
        guard !isDemo, canEdit, let oldRoot = rootURL else { throw LibraryMoveError.notReady }
        guard importTask == nil else { throw LibraryMoveError.importRunning }
        guard stepsInFlight == 0 else { throw LibraryMoveError.stillSaving }
        isMovingLibrary = true
        defer { isMovingLibrary = false }
        if case .note = route {
            go(to: .today)
        }
        await finishPendingSaves(timeout: .seconds(10))
        guard !hasPendingSaves else { throw LibraryMoveError.stillSaving }
        pauseWatching()
        let moving = Task.detached(priority: .userInitiated) { () throws -> URL in
            guard case .move(_, let newRoot) = LibraryFolderChoice.evaluate(chosen, currentRoot: oldRoot) else {
                throw LibraryMoveError.folderChanged
            }
            let fileSystem = LocalFileSystem()
            let isNewFolder = !fileSystem.fileExists(at: newRoot)
            do {
                try LibraryMove.move(from: oldRoot, to: newRoot, fileSystem: fileSystem)
            } catch {
                if isNewFolder, (try? FileManager.default.contentsOfDirectory(atPath: newRoot.path))?.isEmpty == true {
                    try? FileManager.default.removeItem(at: newRoot)
                }
                throw error
            }
            return newRoot
        }
        let newRoot: URL
        do {
            newRoot = try await moving.value
        } catch {
            resumeWatching()
            throw error
        }
        isMovingLibrary = false
        useFolder(newRoot)
    }

    /// Opens another library instead of this one. This one stays as it is.
    func openOtherLibrary(at folder: URL) {
        useFolder(folder)
    }
}
