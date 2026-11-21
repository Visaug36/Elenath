import ElenathCore
import Foundation

/// Why the library changed, for the parts of the app that keep other things in step with it: scheduled
/// alerts and event folders.
enum CalendarChange {
    /// A calendar was opened: with its library, at launch or after choosing, locating or moving the library
    /// folder. `root` is the calendar's folder. Observers refresh what they show, but must never change
    /// anything on disk in response.
    case opened(root: URL)
    /// The calendar was closed: no library is open, or it can't be opened (a space has its name, or it is
    /// damaged). Observers stop following it; nothing on disk changes.
    case closed
    /// The user added an event.
    case added(Event)
    /// The user edited an occurrence. `old` in the callback is the library before the edit.
    case updated(Occurrence, edited: Event, scope: SeriesEditing.Scope)
    /// The user deleted an occurrence (or, with `.allFutureEvents`, the rest of its series).
    case deleted(Occurrence, scope: SeriesEditing.Scope)
    /// Subjects were added, edited or deleted.
    case subjectsChanged
    /// An Ithil calendar was brought in: subjects and events were added, and their folders were copied
    /// into the calendar's folder (already there when this is heard).
    case broughtIn
    /// Undo or Redo put back an earlier version of the calendar (`CalendarModel.restore`), or events.json
    /// changed outside Elenath (`CalendarModel.reloadFromDisk`). `old` in the callback
    /// is the library before, `new` the version put back. Observers bring what they keep in step back in
    /// line; nothing is ever moved to the Trash in response.
    case restored
}

/// Something that reacts to library changes. `CalendarModel` holds observers weakly and calls them on the main
/// actor right after it has updated `library`.
@MainActor
protocol CalendarChangeObserver: AnyObject {
    func calendarDidChange(_ change: CalendarChange, from old: CalendarDocument, to new: CalendarDocument)
}

/// A weak reference to an observer, so `CalendarModel` never keeps one alive.
struct WeakCalendarChangeObserver {
    weak var observer: (any CalendarChangeObserver)?
}
