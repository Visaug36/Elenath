import ElenathCore
import Foundation
import Observation
import os

/// Where the calendar is in opening. The calendar's views show one screen per state.
enum CalendarState: Equatable {
    /// No library is open.
    case closed
    case loading
    case ready
    /// A space made by Elenath 0.1 is called "Calendar", the name the calendar's folder needs. The
    /// calendar opens once the space is renamed.
    case nameTakenBySpace(SpaceID)
    /// events.json is damaged and couldn't be recovered, or the `Calendar` item isn't a folder.
    case unreadable(message: String)
}

private let logger = Logger(subsystem: "io.github.visaug36.Elenath", category: "CalendarModel")

/// The calendar's state (Ithil's `AppModel`, ported): the open calendar, the clock and calendar math,
/// navigation, and every change to events and subjects. Injected once with `.environment(calendar)`.
///
/// - Elenath's `AppModel` opens it whenever a library opens or moves (`open(libraryRoot:libraryID:
///   safetyDirectory:snapshot:)`) and keeps its spaces and subject homes current. The calendar lives in
///   the library's `Calendar` folder, in Ithil's format.
/// - Changes update `library` at once and hand a snapshot to `CalendarSaveQueue`, which saves it on the
///   `CalendarStore` actor; the main thread never waits for the disk. While `isReadOnly` (a file written by
///   a newer version, or a read-only library) or not `.ready`, changes are ignored.
/// - What of an event's content may be shown goes through `reach` (`CalendarReach`): every event's title,
///   time, location and file count show everywhere; its notes, files' names and linked notes only where
///   its home space's content may be read. `workplace` is where the calendar is working: everywhere, or
///   inside one space ("Open in Red Cross").
/// - Queries leave out events of hidden subjects and are cached per library revision and day range, so
///   switching weeks and months stays instant with thousands of events.
/// - `now`, `today` and `math` are kept current by `ClockMonitor` (minute ticks, day changes, time zone
///   and locale changes, wake). `math` is also rebuilt when `AppSettings.firstWeekday` changes.
/// - Every change to events and subjects registers Undo with `undoManager`: a snapshot of the calendar
///   before it, put back by `restore(_:actionName:)`, which registers Redo the same way. Each change is an
///   undo group of its own. Opening a calendar clears its steps, and nothing is registered while the
///   calendar can't be edited.
@Observable @MainActor
final class CalendarModel {
    // MARK: - Calendar

    private(set) var state: CalendarState = .closed
    private(set) var library = CalendarDocument() {
        didSet { eventFilesMayHaveChanged?() }
    }
    /// The calendar is shown, never changed: events.json is from a newer version, or the library is
    /// read-only.
    private(set) var isReadOnly = false
    /// Set after a recovery; the UI shows an alert, then sets nil.
    var recoveryNotice: RecoveryReport? = nil
    /// Set when events.json was lost with nothing to bring it back from and an empty calendar started;
    /// the UI shows an alert, then sets false.
    var startedOverLostFile = false
    /// The last save failure; the UI shows an alert, then sets nil.
    var saveError: String? = nil
    /// The calendar's folder (`<library>/Calendar`), while `.ready`.
    private(set) var rootURL: URL? = nil
    let isDemo: Bool
    /// Bumped on every change to `library`.
    private(set) var libraryRevision = 0

    // MARK: - Spaces and sealing

    /// The library's spaces, kept current by `AppModel`.
    private(set) var spaces: [Space] = []
    /// Elenath's calendar settings from library.json: each subject's home.
    private(set) var calendarSettings = CalendarSettings() {
        didSet { eventFilesMayHaveChanged?() }
    }
    /// Where the calendar is working: everywhere, or inside one space.
    private(set) var workplace: Workplace = .everywhere {
        didSet {
            if workplace != oldValue {
                workplaceChanged?()
            }
        }
    }
    /// Called when the calendar starts working inside a space or everywhere again: the window's own
    /// workplace (its sidebar's tags and folders) follows.
    @ObservationIgnored var workplaceChanged: (@MainActor () -> Void)? = nil
    /// Called when the events, a subject's home or an event folder's files may have changed: the index works out
    /// again which event files it holds, and in which space (`CalendarReach.indexedHomes`). Set by `AppModel`.
    @ObservationIgnored var eventFilesMayHaveChanged: (@MainActor () -> Void)? = nil
    /// What of each event's content may be read from `workplace`.
    var reach: CalendarReach {
        CalendarReach(workplace: workplace, spaces: spaces, settings: calendarSettings)
    }
    /// Saves calendar settings into library.json; set by `AppModel`.
    @ObservationIgnored var saveSettings: (@MainActor (CalendarSettings) async throws -> Void)? = nil
    /// Shows the calendar in the main window; set by `AppModel`.
    @ObservationIgnored var showCalendar: (@MainActor () -> Void)? = nil

    // MARK: - Clock and calendar

    private(set) var now: Date
    /// Display time zone and first weekday.
    private(set) var math: CalendarMath
    private(set) var today: CalendarDate
    var timeZone: TimeZone { math.timeZone }

    // MARK: - Navigation

    /// Default `.week`.
    var span: CalendarSpan = .week
    /// The day the views are centered on.
    var selectedDate: CalendarDate
    var selectedOccurrenceID: Occurrence.ID? = nil
    /// The toolbar search field while the calendar is open. Editing it brings the results back.
    var searchText = "" {
        didSet {
            if searchText != oldValue {
                isSearchDismissed = false
            }
        }
    }
    /// Set after choosing a search result, so the calendar is on screen while the query stays in the field.
    var isSearchDismissed = false
    /// Set by Quick Add ⌘↩: the calendar opens this occurrence's editor, then sets nil.
    var pendingEditorOccurrenceID: Occurrence.ID? = nil
    /// Set by a `-demo` screenshot scene: the calendar opens this occurrence's details.
    var pendingDetailsOccurrenceID: Occurrence.ID? = nil
    /// Set by File › New Event… (⌘N): the toolbar's + opens a new event's editor, then sets false.
    var requestsNewEvent = false
    var visibleDays: [CalendarDate] { math.visibleDays(for: span, around: selectedDate) }

    // MARK: - Undo

    /// The main window's undo manager; `MainView` sets it from `@Environment(\.undoManager)`. Edit › Undo
    /// and Redo there step through changes to events and subjects. Each step holds a copy of the library,
    /// so at most `undoLevels` steps are kept.
    @ObservationIgnored weak var undoManager: UndoManager? {
        didSet {
            if let undoManager, undoManager !== oldValue, undoManager.levelsOfUndo == 0 {
                undoManager.levelsOfUndo = Self.undoLevels
            }
        }
    }

    /// How many Undo steps are kept (with thousands of events, each one holds a sizeable snapshot).
    private static let undoLevels = 100

    // MARK: - Subjects

    /// Persisted per Mac, not in the library.
    private(set) var hiddenSubjectIDs: Set<UUID>

    // MARK: - Private state

    private let settings: AppSettings
    private let defaults: UserDefaults
    private let timeSource: any TimeSource
    @ObservationIgnored private var expander: OccurrenceExpander
    @ObservationIgnored private var clock: ClockMonitor?
    @ObservationIgnored private var hasStarted = false
    /// Bumped whenever a library opens; reports from an earlier library's save queue are dropped.
    @ObservationIgnored private var librarySession = 0
    /// Bumped by every attempt to open a calendar; results of older attempts are dropped.
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var store: CalendarStore? = nil
    @ObservationIgnored private var changeObservers: [WeakCalendarChangeObserver] = []
    @ObservationIgnored private var saveQueue: CalendarSaveQueue?
    /// Numbers every snapshot handed to the save queue, retries included.
    @ObservationIgnored private var saveNumber = 0
    @ObservationIgnored private var lastFinishedSaveNumber = 0
    @ObservationIgnored private var occurrenceCache = OccurrenceCache()
    @ObservationIgnored private var cacheStamp: CacheStamp?
    @ObservationIgnored private var visibleEventsCache: [Event]?
    @ObservationIgnored private var upNextCache: (key: UpNextKey, value: [Occurrence])?
    @ObservationIgnored private var searchCache: (key: SearchKey, value: [Occurrence])?
    @ObservationIgnored private var eventPositions: [UUID: Int]?
    /// The last subject edit that registered Undo, so quick edits of one subject (typing its name,
    /// dragging the color picker) become one Undo step.
    @ObservationIgnored private var lastSubjectEdit: SubjectEditUndo?

    init(options: LaunchOptions, settings: AppSettings, defaults: UserDefaults) {
        let timeSource = options.timeSource
        let now = timeSource.now
        let math = CalendarMath(timeZone: .current, firstWeekday: settings.effectiveFirstWeekday)
        let today = math.today(now: now)
        self.isDemo = options.isDemo
        self.settings = settings
        self.defaults = defaults
        self.timeSource = timeSource
        self.now = now
        self.math = math
        self.today = today
        self.selectedDate = today
        self.expander = OccurrenceExpander(displayTimeZone: math.timeZone)
        self.hiddenSubjectIDs = CalendarModel.storedHiddenSubjectIDs(in: defaults)
    }

    /// Starts the clock. Call once at launch; later calls do nothing. The calendar opens when the library
    /// does.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        let clock = ClockMonitor(model: self)
        clock.start()
        self.clock = clock
        observeFirstWeekday()
    }

    /// Whether the library can be changed right now.
    var canEdit: Bool { state == .ready && !isReadOnly && !isMovingLibrary }

    /// Set by `AppModel` while it moves the library to another folder: no changes until the calendar has
    /// reopened there, so no save lands in a folder that is being moved.
    var isMovingLibrary = false

    // MARK: - Navigation

    func goToToday() {
        selectedDate = today
    }

    /// Moves ‹ / › by the current span.
    func step(_ count: Int) {
        selectedDate = math.step(selectedDate, by: span, count: count)
    }

    func show(_ date: CalendarDate, span: CalendarSpan?) {
        selectedDate = date
        if let span, span != self.span {
            self.span = span
        }
    }

    // MARK: - Subjects

    /// Events without a subject are always visible.
    func isVisible(_ subjectID: UUID?) -> Bool {
        guard let subjectID else { return true }
        return !hiddenSubjectIDs.contains(subjectID)
    }

    func setVisible(_ visible: Bool, subjectID: UUID) {
        guard visible == hiddenSubjectIDs.contains(subjectID) else { return }
        if visible {
            hiddenSubjectIDs.remove(subjectID)
        } else {
            hiddenSubjectIDs.insert(subjectID)
        }
        storeHiddenSubjectIDs()
    }

    func subject(for event: Event) -> Subject? {
        library.subject(withID: event.subjectID)
    }

    /// Adds a subject, or replaces the one with the same ID.
    func addSubject(_ subject: Subject) {
        guard canEdit else { return }
        var updated = library
        if let index = updated.subjects.firstIndex(where: { $0.id == subject.id }) {
            updated.subjects[index] = subject
        } else {
            updated.subjects.append(subject)
        }
        let old = library
        commit(updated)
        registerUndo(restoring: old, action: .editSubjects)
        notifyObservers(.subjectsChanged, from: old)
    }

    func updateSubject(_ subject: Subject) {
        guard canEdit, let index = library.subjects.firstIndex(where: { $0.id == subject.id }) else { return }
        guard library.subjects[index] != subject else { return }
        var updated = library
        updated.subjects[index] = subject
        let old = library
        commit(updated)
        registerSubjectEditUndo(restoring: old, subjectID: subject.id)
        notifyObservers(.subjectsChanged, from: old)
    }

    /// Removes the subject. Its events keep existing with no subject. Never when that would bring their
    /// content out of a seal (`CalendarReach.deletingSubjectWouldUnseal`): Settings explains that first.
    func deleteSubject(id: UUID) {
        guard canEdit, library.subjects.contains(where: { $0.id == id }),
            !reach.deletingSubjectWouldUnseal(id, in: library)
        else { return }
        var updated = library
        updated.subjects.removeAll { $0.id == id }
        let stamp = timeSource.now.roundedToSecond
        for index in updated.events.indices where updated.events[index].subjectID == id {
            updated.events[index].subjectID = nil
            updated.events[index].modifiedAt = stamp
        }
        let old = library
        commit(updated)
        registerUndo(restoring: old, action: .editSubjects)
        notifyObservers(.subjectsChanged, from: old)
        if hiddenSubjectIDs.contains(id) {
            hiddenSubjectIDs.remove(id)
            storeHiddenSubjectIDs()
        }
    }

    // MARK: - Queries

    /// The occurrences that overlap `days` (from the earliest to the latest), visible subjects only,
    /// sorted.
    func occurrences(in days: [CalendarDate]) -> [Occurrence] {
        guard let first = days.min(), let last = days.max() else { return [] }
        return occurrences(from: first, through: last)
    }

    /// The occurrences that overlap `day`, visible subjects only, sorted. Filtered from the cached month
    /// grid around the day, so asking for every day of a month expands the events only once.
    func occurrences(on day: CalendarDate) -> [Occurrence] {
        let key = cacheKey(from: day, through: day)
        if let cached = occurrenceCache.value(for: key) { return cached }
        let candidates = occurrenceCache.value(covering: day, like: key) ?? occurrences(inMonthGridOf: day)
        let interval = math.interval(from: day, through: day)
        let result = candidates.filter { CalendarModel.overlaps($0, interval) }
        occurrenceCache.insert(result, for: key)
        return result
    }

    /// The next 4 occurrences that haven't started yet, visible subjects only.
    var upNext: [Occurrence] {
        let key = UpNextKey(stamp: currentCacheStamp(), now: now)
        if let cached = upNextCache, cached.key == key { return cached.value }
        let value = expander.upcoming(visibleEvents(), after: now, limit: 4, horizonDays: 60)
        upNextCache = (key, value)
        return value
    }

    /// The calendar's own search over `searchText`, visible subjects only, through `reach`: every event by
    /// its title and location, and by its notes only where they may be read. Empty for a blank query.
    var searchResults: [Occurrence] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let reach = reach
        let key = SearchKey(stamp: currentCacheStamp(), now: now, query: query, reach: reach)
        if let cached = searchCache, cached.key == key { return cached.value }
        let visible = CalendarDocument(id: library.id, subjects: library.subjects, events: visibleEvents())
        let value = reach.search(visible, query: query, now: now, expander: expander)
        searchCache = (key, value)
        return value
    }

    /// The occurrence with this ID, whatever its subject's visibility. Nil if it no longer exists.
    func occurrence(id: Occurrence.ID) -> Occurrence? {
        guard let event = event(withID: id.eventID) else { return nil }
        return expander.occurrence(of: event, on: id.date)
    }

    private func occurrences(from first: CalendarDate, through last: CalendarDate) -> [Occurrence] {
        let key = cacheKey(from: first, through: last)
        if let cached = occurrenceCache.value(for: key) { return cached }
        let interval = math.interval(from: first, through: last)
        let result = expander.occurrences(of: visibleEvents(), in: interval)
        occurrenceCache.insert(result, for: key)
        return result
    }

    /// Every week of a month grid lies inside it, so the week and day views reuse it too.
    private func occurrences(inMonthGridOf day: CalendarDate) -> [Occurrence] {
        let grid = math.monthGrid(year: day.year, month: day.month)
        guard let first = grid.first, let last = grid.last, first <= day, day <= last else {
            return occurrences(from: day, through: day)
        }
        return occurrences(from: first, through: last)
    }

    /// The same overlap rule as `OccurrenceExpander`: an occurrence overlaps when it starts before the
    /// end and ends after the start; a zero-length one when it starts inside.
    private static func overlaps(_ occurrence: Occurrence, _ interval: DateInterval) -> Bool {
        if occurrence.end > occurrence.start {
            return occurrence.start < interval.end && occurrence.end > interval.start
        }
        return occurrence.start >= interval.start && occurrence.start < interval.end
    }

    private func cacheKey(from first: CalendarDate, through last: CalendarDate) -> OccurrenceCache.Key {
        let stamp = currentCacheStamp()
        return OccurrenceCache.Key(
            revision: stamp.revision, hiddenSubjectIDs: stamp.hiddenSubjectIDs, timeZone: stamp.timeZone,
            first: first, last: last)
    }

    /// What every cached query depends on. Reading it also registers those properties with Observation,
    /// so views that query the model update when any of them changes. A new stamp empties the caches.
    private func currentCacheStamp() -> CacheStamp {
        let stamp = CacheStamp(revision: libraryRevision, hiddenSubjectIDs: hiddenSubjectIDs, timeZone: math.timeZone)
        if stamp != cacheStamp {
            cacheStamp = stamp
            occurrenceCache.removeAll()
            visibleEventsCache = nil
            eventPositions = nil
        }
        return stamp
    }

    private func visibleEvents() -> [Event] {
        _ = currentCacheStamp()
        if let cached = visibleEventsCache { return cached }
        let hidden = hiddenSubjectIDs
        let events: [Event]
        if hidden.isEmpty {
            events = library.events
        } else {
            events = library.events.filter { event in
                guard let subjectID = event.subjectID else { return true }
                return !hidden.contains(subjectID)
            }
        }
        visibleEventsCache = events
        return events
    }

    private func event(withID id: UUID) -> Event? {
        _ = currentCacheStamp()
        let positions: [UUID: Int]
        if let cached = eventPositions {
            positions = cached
        } else {
            var built: [UUID: Int] = [:]
            built.reserveCapacity(library.events.count)
            for (position, event) in library.events.enumerated() {
                built[event.id] = position
            }
            eventPositions = built
            positions = built
        }
        guard let position = positions[id], library.events.indices.contains(position) else { return nil }
        return library.events[position]
    }

    // MARK: - Events

    /// A new one-hour timed event in the current time zone with the default alert, not yet added. It
    /// starts at `startMinute`, or else at the next whole hour today and at 9:00 on other days.
    func newEvent(on day: CalendarDate, startMinute: Int?) -> Event {
        let minute = startMinute.map { min(max($0, 0), 24 * 60 - 1) } ?? defaultStartMinute(on: day)
        let calendar = math.calendar
        let parts = DateComponents(
            year: day.year, month: day.month, day: day.day, hour: minute / 60, minute: minute % 60)
        let start = calendar.date(from: parts) ?? day.start(in: timeZone)
        let end = calendar.date(byAdding: .hour, value: 1, to: start) ?? start.addingTimeInterval(60 * 60)
        return Event(
            title: "", timing: .timed(start: start, end: end, timeZone: timeZone), alert: settings.defaultAlert,
            createdAt: timeSource.now)
    }

    private func defaultStartMinute(on day: CalendarDate) -> Int {
        guard day == today else { return 9 * 60 }
        let nextHour = math.minutesOfDay(now) / 60 + 1
        return min(nextHour, 23) * 60
    }

    func add(_ event: Event) {
        guard canEdit, !library.events.contains(where: { $0.id == event.id }) else { return }
        var updated = library
        updated.events.append(event)
        let old = library
        commit(updated)
        registerUndo(restoring: old, action: .addEvent)
        notifyObservers(.added(event), from: old)
    }

    /// Applies an edit (`SeriesEditing.update`). `undoAction` names it in Edit › Undo: "Edit Event", or
    /// "Move Event" when the calendar's drag or ⌥-arrow keys moved it.
    func update(
        _ occurrence: Occurrence,
        with edited: Event,
        scope: SeriesEditing.Scope,
        undoAction: CalendarUndoAction = .editEvent
    ) {
        guard canEdit else { return }
        var updated = library
        SeriesEditing.update(occurrence, with: edited, scope: scope, in: &updated, now: timeSource.now)
        guard updated != library else { return }
        let old = library
        commit(updated)
        registerUndo(restoring: old, action: undoAction)
        notifyObservers(.updated(occurrence, edited: edited, scope: scope), from: old)
        if selectedOccurrenceID == occurrence.id, self.occurrence(id: occurrence.id) == nil {
            // A rescheduled single event keeps its ID and moves to its new day.
            let moved = Occurrence.ID(eventID: occurrence.event.id, date: edited.timing.startDate)
            selectedOccurrenceID = self.occurrence(id: moved) != nil ? moved : nil
        }
    }

    func delete(_ occurrence: Occurrence, scope: SeriesEditing.Scope) {
        guard canEdit else { return }
        var updated = library
        SeriesEditing.delete(occurrence, scope: scope, from: &updated)
        guard updated != library else { return }
        let old = library
        commit(updated)
        registerUndo(restoring: old, action: .deleteEvent)
        notifyObservers(.deleted(occurrence, scope: scope), from: old)
        clearSelectionIfGone()
    }

    /// Takes in the calendar `CalendarImport` merged an Ithil calendar into: its subjects and events are
    /// added as one change, which Undo takes back (the copied event folders stay; they are copies).
    func bringIn(_ merged: CalendarDocument) {
        guard canEdit, merged.id == library.id, merged != library else { return }
        let old = library
        commit(merged)
        registerUndo(restoring: old, action: .bringIn)
        notifyObservers(.broughtIn, from: old)
    }

    // MARK: - Undo and Redo

    /// Puts back an earlier version of the library for Undo or Redo, and registers the opposite step
    /// (Redo after an Undo, Undo after a Redo) under the same name. Observers hear `.restored`: event
    /// folders follow along, and folders trashed by the change being undone come back from the Trash.
    ///
    /// Ignored while the library can't be edited, and for a snapshot of another library.
    func restore(_ snapshot: CalendarDocument, actionName: String) {
        guard canEdit, snapshot.id == library.id else { return }
        let old = library
        lastSubjectEdit = nil
        guard snapshot != old else {
            registerRestore(of: old, actionName: actionName)
            return
        }
        commit(snapshot)
        registerRestore(of: old, actionName: actionName)
        notifyObservers(.restored, from: old)
        clearSelectionIfGone()
        if let pending = pendingEditorOccurrenceID, occurrence(id: pending) == nil {
            pendingEditorOccurrenceID = nil
        }
    }

    /// Registers Undo for the change just committed: `restore` puts `old` back.
    private func registerUndo(restoring old: CalendarDocument, action: CalendarUndoAction) {
        lastSubjectEdit = nil
        registerRestore(of: old, actionName: action.name)
    }

    /// Edits of the same subject less than two seconds apart, with no other change in between, share the
    /// Undo step of the first one.
    private func registerSubjectEditUndo(restoring old: CalendarDocument, subjectID: UUID) {
        let now = ContinuousClock.now
        var continues = false
        if let last = lastSubjectEdit {
            continues = last.isContinued(by: subjectID, revision: libraryRevision, at: now, undoManager: undoManager)
        }
        if !continues {
            registerUndo(restoring: old, action: .editSubjects)
        }
        guard let undoManager, undoManager.canUndo else {
            lastSubjectEdit = nil
            return
        }
        lastSubjectEdit = SubjectEditUndo(
            subjectID: subjectID, revision: libraryRevision, time: now, undoManager: undoManager)
    }

    /// Registers a step that puts `snapshot` back. Never while the library can't be edited (loading,
    /// read-only, moving), so a folder written by a newer Ithil never gets an Undo.
    private func registerRestore(of snapshot: CalendarDocument, actionName: String) {
        guard canEdit, let undoManager else { return }
        // Each change is a group of its own, also without a user event (Bring In after its copy, the crash
        // check): AppKit would otherwise put it in one group with the changes after it.
        undoManager.registerAsOwnGroup {
            undoManager.registerUndo(withTarget: self) { model in
                MainActor.assumeIsolated {
                    model.restore(snapshot, actionName: actionName)
                }
            }
            undoManager.setActionName(actionName)
        }
    }

    /// Forgets the selection when its occurrence no longer exists.
    private func clearSelectionIfGone() {
        if let selected = selectedOccurrenceID, occurrence(id: selected) == nil {
            selectedOccurrenceID = nil
        }
    }

    /// Subjects are matched against the library as it is now; make a new parser after subjects change.
    func makeQuickAddParser() -> QuickAddParser {
        QuickAddParser(
            subjects: library.subjects, timeZone: timeZone, defaultDuration: 60 * 60,
            defaultAlert: settings.defaultAlert)
    }

    // MARK: - Quick Capture

    /// What Quick Capture's ⌥↩ would add for `text` (`CaptureEvent`): the event its first line names, sent
    /// to the space the text starts with. Nil for a note, and when that space is sealed and no subject lives
    /// there (`captureReading(for:)` tells that apart).
    func captureEvent(for text: String) -> QuickAddDraft? {
        guard case .event(let draft) = captureReading(for: text) else { return nil }
        return draft
    }

    /// How Quick Capture reads `text` as an event: an event, a sealed space where no subject lives, or nil.
    func captureReading(for text: String) -> CaptureEvent.Reading? {
        guard state == .ready else { return nil }
        let parser = makeQuickAddParser()
        let now = now
        return CaptureEvent.read(text, spaces: spaces, subjects: library.subjects, settings: calendarSettings) {
            parser.parse($0, now: now)
        }
    }

    /// The event for a draft from `captureEvent(for:)`, not yet added.
    func makeEvent(from draft: QuickAddDraft) -> Event {
        makeQuickAddParser().makeEvent(
            from: draft, fallbackTitle: String(localized: "New Event"), now: timeSource.now)
    }

    /// Copies files dropped on Quick Capture into a new event's folder; set by the app (`FilesController`).
    @ObservationIgnored var filesForNewEvent: (@MainActor ([URL], Occurrence) -> Void)? = nil
    /// Whether files are being copied into an event (`FilesController`); moving the library waits for none.
    @ObservationIgnored var isCopyingFiles: (@MainActor () -> Bool)? = nil
    /// Waits for the event folders' disk work to finish, up to a timeout; true when it has.
    @ObservationIgnored var finishFileWork: (@MainActor (Duration) async -> Bool)? = nil

    // MARK: - Saving

    /// Whether a change hasn't finished saving (successfully or not) yet.
    var hasPendingSaves: Bool { lastFinishedSaveNumber < saveNumber }

    /// Waits until every change handed to the save queue has been written, or `timeout` passes.
    func finishPendingSaves(timeout: Duration) async {
        let deadline = ContinuousClock.now + timeout
        while hasPendingSaves, ContinuousClock.now < deadline {
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                return
            }
        }
    }

    /// Saves the current library again, after a failed save.
    func retrySave() {
        saveError = nil
        guard canEdit else { return }
        scheduleSave()
    }

    var showsRecoveryNotice: Bool {
        get { recoveryNotice != nil }
        set {
            if !newValue {
                recoveryNotice = nil
            }
        }
    }

    var showsSaveError: Bool {
        get { saveError != nil }
        set {
            if !newValue {
                saveError = nil
            }
        }
    }

    // MARK: - Change observers

    /// Registers an observer (held weakly) that hears about every library change from now on.
    func addChangeObserver(_ observer: any CalendarChangeObserver) {
        changeObservers.removeAll { $0.observer == nil || $0.observer === observer }
        changeObservers.append(WeakCalendarChangeObserver(observer: observer))
    }

    private func notifyObservers(_ change: CalendarChange, from old: CalendarDocument) {
        changeObservers.removeAll { $0.observer == nil }
        let current = library
        for entry in changeObservers {
            entry.observer?.calendarDidChange(change, from: old, to: current)
        }
    }

    private func commit(_ updated: CalendarDocument) {
        library = updated
        libraryRevision += 1
        scheduleSave()
    }

    private func scheduleSave() {
        guard let saveQueue else { return }
        let snapshot = library
        saveNumber += 1
        let number = saveNumber
        Task {
            await saveQueue.enqueue(snapshot, number: number)
        }
    }

    private func saveFinished(number: Int, error: (any Error)?, session: Int) {
        guard session == librarySession else { return }
        lastFinishedSaveNumber = max(lastFinishedSaveNumber, number)
        guard let error else { return }
        if (error as? DocumentStoreError) == .readOnly {
            isReadOnly = true
            saveQueue = nil
        }
        saveError = CalendarMessages.saveFailed(error)
    }

    // MARK: - Opening

    /// Opens the calendar of the library that just opened or moved. Spaces and homes come with the
    /// library; in a read-only library the calendar is read-only too.
    func open(libraryRoot: URL, libraryID: LibraryID, safetyDirectory: URL, snapshot: LibrarySnapshot) {
        loadGeneration += 1
        let generation = loadGeneration
        spaces = snapshot.spaces
        calendarSettings = snapshot.calendarSettings
        workplace = .everywhere
        saveQueue = nil
        store = nil
        if let space = snapshot.spaceNamedCalendar {
            closeCalendar(as: .nameTakenBySpace(space))
            return
        }
        state = .loading
        let store = CalendarStore(
            libraryRoot: libraryRoot, libraryID: libraryID, safetyDirectory: safetyDirectory,
            knownCalendarID: snapshot.calendarSettings.calendarID, fileSystem: LocalFileSystem(),
            timeSource: timeSource)
        let readOnly = snapshot.isReadOnly
        Task {
            do {
                let load = try await store.load(readOnly: readOnly)
                guard generation == loadGeneration else { return }
                didOpen(load, store: store)
            } catch CalendarStoreError.nameTakenBySpace {
                guard generation == loadGeneration else { return }
                let calendarKey = NameSanitizer.key(NameSanitizer.calendarFolderName)
                let space = spaces.first { NameSanitizer.key($0.name) == calendarKey }
                closeCalendar(as: .nameTakenBySpace(space?.id ?? SpaceID()))
            } catch {
                guard generation == loadGeneration else { return }
                let reason = String(describing: error)
                logger.error("Could not open the calendar: \(reason, privacy: .private)")
                closeCalendar(as: .unreadable(message: CalendarMessages.couldNotOpen(error)))
            }
        }
    }

    /// Closes the calendar: no library is open any more.
    func close() {
        loadGeneration += 1
        saveQueue = nil
        store = nil
        closeCalendar(as: .closed)
    }

    /// The library's spaces or calendar settings changed (a space was sealed, renamed, added or trashed,
    /// or a home was set). What may be read follows at once.
    func libraryChanged(spaces: [Space], calendarSettings: CalendarSettings) {
        if spaces != self.spaces {
            self.spaces = spaces
        }
        if calendarSettings != self.calendarSettings {
            self.calendarSettings = calendarSettings
        }
        if case .space(let id) = workplace, !spaces.contains(where: { $0.id == id }) {
            workplace = .everywhere
        }
        settleDamagedSettings()
    }

    /// Calendar settings found damaged in library.json (`CalendarSettings.isDamaged`) are settled for the
    /// calendar's subjects: each keeps its events sealed until it has a home again.
    private func settleDamagedSettings() {
        guard canEdit, calendarSettings.isDamaged else { return }
        var updated = calendarSettings
        guard updated.settleDamage(subjects: library.subjects.map(\.id)) else { return }
        calendarSettings = updated
        persistSettings(updated)
    }

    /// events.json changed outside Elenath (Finder, a sync, another app): reads it again and shows it, unless
    /// a change of Elenath's own is still being saved (that save wins). Undo steps of the calendar shown
    /// before are dropped.
    func reloadFromDisk() {
        guard state == .ready, !isReadOnly, !hasPendingSaves, let store else { return }
        let generation = loadGeneration
        let session = librarySession
        Task {
            guard let load = try? await store.load() else { return }
            guard generation == loadGeneration, session == librarySession, !hasPendingSaves else { return }
            // A file from a newer version (through a synced folder) makes the calendar read-only, as at open:
            // a change made now couldn't be saved. A file recovered from a backup is said, as at open.
            if load.isReadOnly, !isReadOnly {
                logger.notice("events.json is from a newer version now; the calendar is read-only")
                isReadOnly = true
                saveQueue = nil
                undoManager?.removeAllActions(withTarget: self)
                lastSubjectEdit = nil
            }
            if let recovery = load.recovery {
                recoveryNotice = recovery
            }
            guard load.document != library, load.document.id == library.id else { return }
            logger.notice("events.json changed outside Elenath; showing the new version")
            let old = library
            library = load.document
            libraryRevision += 1
            undoManager?.removeAllActions(withTarget: self)
            lastSubjectEdit = nil
            notifyObservers(.restored, from: old)
            clearSelectionIfGone()
        }
    }

    /// Gives a subject a home (or none), in library.json. Not an undo step, like a space's settings.
    func setHome(_ home: SubjectHome?, forSubject subject: UUID) {
        guard canEdit else { return }
        var updated = calendarSettings
        updated.setHome(home, forSubject: subject)
        guard updated != calendarSettings else { return }
        calendarSettings = updated
        persistSettings(updated)
    }

    /// Works inside a space, or everywhere again: what of each event's content may be read follows.
    func work(in workplace: Workplace) {
        guard workplace != self.workplace else { return }
        self.workplace = workplace
    }

    /// Shows an occurrence in the calendar, selected, and brings the calendar forward in the main window.
    func reveal(_ occurrence: Occurrence) {
        show(EventFormatting.displayDay(of: occurrence, timeZone: timeZone), span: nil)
        selectedOccurrenceID = occurrence.id
        showCalendar?()
    }

    private func closeCalendar(as newState: CalendarState) {
        librarySession += 1
        let old = library
        library = CalendarDocument()
        libraryRevision += 1
        rootURL = nil
        isReadOnly = true
        selectedOccurrenceID = nil
        pendingEditorOccurrenceID = nil
        pendingDetailsOccurrenceID = nil
        undoManager?.removeAllActions(withTarget: self)
        lastSubjectEdit = nil
        state = newState
        notifyObservers(.closed, from: old)
    }

    private func didOpen(_ load: CalendarLoad, store: CalendarStore) {
        librarySession += 1
        let session = librarySession
        let old = library
        library = load.document
        libraryRevision += 1
        lastFinishedSaveNumber = saveNumber
        isReadOnly = load.isReadOnly
        rootURL = store.folder
        recoveryNotice = load.recovery
        startedOverLostFile = load.startedOverLostFile
        saveError = nil
        selectedOccurrenceID = nil
        pendingEditorOccurrenceID = nil
        // Undo steps hold snapshots of the calendar that was open before.
        undoManager?.removeAllActions(withTarget: self)
        lastSubjectEdit = nil
        self.store = store
        if load.isReadOnly {
            saveQueue = nil
        } else {
            saveQueue = CalendarSaveQueue(store: store) { [weak self] number, error in
                self?.saveFinished(number: number, error: error, session: session)
            }
            // Damaged settings are settled for this calendar's subjects, and the calendar's id goes into
            // library.json, so its safety copy is found if its folder is lost.
            var updated = calendarSettings
            var changed = updated.settleDamage(subjects: load.document.subjects.map(\.id))
            if updated.calendarID != load.document.id {
                updated.calendarID = load.document.id
                changed = true
            }
            if changed {
                calendarSettings = updated
                persistSettings(updated)
            }
        }
        state = .ready
        notifyObservers(.opened(root: store.folder), from: old)
    }

    private func persistSettings(_ updated: CalendarSettings) {
        guard let saveSettings else { return }
        Task {
            do {
                try await saveSettings(updated)
            } catch {
                let reason = String(describing: error)
                logger.error("Could not save the calendar settings: \(reason, privacy: .private)")
                saveError = CalendarMessages.settingsSaveFailed(error)
            }
        }
    }

    // MARK: - Clock

    /// Re-reads the clock (minute ticks, day changes, clock changes). If the day changed while the
    /// views were on today, they follow to the new today.
    func refreshClock() {
        let current = timeSource.now
        guard current != now else { return }
        let previousToday = today
        now = current
        updateToday(from: previousToday)
    }

    /// Rebuilds the calendar math for the current time zone, locale and first-weekday setting, then
    /// re-reads the clock (time zone and locale changes, wake, Settings).
    func refreshCalendar() {
        NSTimeZone.resetSystemTimeZone()
        let zone = TimeZone.current
        let weekday = settings.effectiveFirstWeekday
        let previousToday = today
        if zone != math.timeZone || weekday != math.firstWeekday {
            math = CalendarMath(timeZone: zone, firstWeekday: weekday)
            expander = OccurrenceExpander(displayTimeZone: zone)
        }
        let current = timeSource.now
        if current != now {
            now = current
        }
        updateToday(from: previousToday)
    }

    private func updateToday(from previousToday: CalendarDate) {
        let newToday = math.today(now: now)
        guard newToday != today else { return }
        today = newToday
        if selectedDate == previousToday {
            selectedDate = newToday
        }
    }

    /// Rebuilds `math` whenever the first-weekday setting changes.
    private func observeFirstWeekday() {
        withObservationTracking {
            _ = settings.firstWeekday
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refreshCalendar()
                self?.observeFirstWeekday()
            }
        }
    }

    // MARK: - Hidden subjects

    private enum Key {
        static let hiddenSubjectIDs = "hiddenSubjectIDs"
    }

    private static func storedHiddenSubjectIDs(in defaults: UserDefaults) -> Set<UUID> {
        let strings = defaults.stringArray(forKey: Key.hiddenSubjectIDs) ?? []
        return Set(strings.compactMap { UUID(uuidString: $0) })
    }

    private func storeHiddenSubjectIDs() {
        defaults.set(hiddenSubjectIDs.map(\.uuidString).sorted(), forKey: Key.hiddenSubjectIDs)
    }
}

/// What Edit › Undo and Redo call a change to the library: "Undo Move Event".
enum CalendarUndoAction {
    case addEvent
    case editEvent
    case moveEvent
    case deleteEvent
    case editSubjects
    case bringIn

    var name: String {
        switch self {
        case .addEvent:
            return String(localized: "Add Event")
        case .editEvent:
            return String(localized: "Edit Event")
        case .moveEvent:
            return String(localized: "Move Event")
        case .deleteEvent:
            return String(localized: "Delete Event")
        case .editSubjects:
            return String(localized: "Edit Subjects")
        case .bringIn:
            return String(localized: "Bring In Ithil Calendar")
        }
    }
}

/// The last subject edit that registered Undo (see `CalendarModel.registerSubjectEditUndo`).
private struct SubjectEditUndo {
    var subjectID: UUID
    /// `libraryRevision` right after the edit.
    var revision: Int
    var time: ContinuousClock.Instant
    weak var undoManager: UndoManager?

    /// Whether an edit of `subjectID` that brought the library to `revision` at `time` continues this one:
    /// the same subject, nothing else changed in between, soon after, and this edit's Undo still on top.
    @MainActor
    func isContinued(
        by subjectID: UUID,
        revision: Int,
        at time: ContinuousClock.Instant,
        undoManager: UndoManager?
    ) -> Bool {
        guard subjectID == self.subjectID, revision == self.revision + 1, time - self.time < .seconds(2) else {
            return false
        }
        guard let undoManager, undoManager === self.undoManager, undoManager.canUndo else { return false }
        guard !undoManager.isUndoing, !undoManager.isRedoing else { return false }
        return undoManager.undoActionName == CalendarUndoAction.editSubjects.name
    }
}

/// What every cached query depends on besides its own arguments.
private struct CacheStamp: Hashable {
    var revision: Int
    var hiddenSubjectIDs: Set<UUID>
    var timeZone: TimeZone
}

private struct UpNextKey: Hashable {
    var stamp: CacheStamp
    var now: Date
}

private struct SearchKey: Hashable {
    var stamp: CacheStamp
    var now: Date
    var query: String
    /// What may be searched: sealing and the workplace change the results.
    var reach: CalendarReach
}
