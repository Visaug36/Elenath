import Foundation

/// A Trash of a test's own, inside its temporary folder, so it goes when the test cleans up.
///
/// The file tests used to move folders to the real Trash. Tests run in parallel and trash folders with the
/// same names ("14.00 Physics Lecture"), so a test cleaning up the place its folder had been in the Trash
/// could delete another test's folder, and tests failed at random (while filling the developer's Trash).
/// Each item goes into a new subfolder of its own, so it keeps its name, as it usually does in the real Trash.
struct TestTrash: Sendable {
    let directory: URL

    init(in base: URL) {
        directory = base.appending(component: "Trash", directoryHint: .isDirectory)
    }

    /// Moves `url` into this Trash and returns where it is now.
    func trash(_ url: URL) throws -> URL {
        let slot = directory.appending(component: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: slot, withIntermediateDirectories: true, attributes: nil)
        let item = slot.appending(component: url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: item)
        return item
    }
}
