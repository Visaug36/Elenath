import Foundation

/// An event folder whose files are indexed, and the space they are indexed into (docs/ARCHITECTURE.md, "PDFs,
/// pictures and event files"). The files become rows of that space's index, so its seal applies to them.
public struct EventFolderHome: Hashable, Sendable {
    public var occurrence: EventLink
    /// The event folder, relative to the calendar folder: "2026-11-16/14.00 Physics Lecture".
    public var folder: ItemPath
    public var space: SpaceID
    /// The home's folder in that space: a search narrowed to it finds the event's files.
    public var homeFolder: ItemPath

    public init(occurrence: EventLink, folder: ItemPath, space: SpaceID, homeFolder: ItemPath) {
        self.occurrence = occurrence
        self.folder = folder
        self.space = space
        self.homeFolder = homeFolder
    }
}

extension CalendarReach {
    /// Where each event folder's files are indexed: the space of its event's home (`home(of:)`). Folders of
    /// events without a home or with one that can't be used, folders no event of `document` claims, and folders
    /// outside `calendarFolder` are left out: their files are indexed nowhere. The same from every workplace.
    public func indexedHomes(
        of folders: [Occurrence.ID: URL], in document: CalendarDocument, calendarFolder: URL
    ) -> [EventFolderHome] {
        let events = Dictionary(document.events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let base = calendarFolder.standardizedFileURL.pathComponents
        var homes: [EventFolderHome] = []
        for (occurrence, url) in folders {
            guard let event = events[occurrence.eventID], let home = home(of: event) else { continue }
            let components = url.standardizedFileURL.pathComponents
            guard components.count > base.count, components.starts(with: base),
                let folder = ItemPath(components.dropFirst(base.count).joined(separator: "/"))
            else { continue }
            homes.append(
                EventFolderHome(
                    occurrence: EventLink(occurrence), folder: folder, space: home.space, homeFolder: home.folder))
        }
        return homes.sorted { $0.folder.description < $1.folder.description }
    }
}
