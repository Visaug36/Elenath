import ElenathCore
import Foundation

/// What the launch arguments ask for.
///
/// - `-demo` loads an invented sample library into a fresh temporary folder, with throwaway settings. The
///   user's own folder, bookmark and settings are never read or written.
/// - `-demoNow 2026-11-10T14:30` (local time) additionally pins the clock, for screenshots. It only takes
///   effect together with `-demo`, so a stray argument can never freeze the clock on real data.
/// - The screenshot flags (see `DemoScene`) only take effect together with `-demo` too.
struct LaunchOptions: Sendable {
    var isDemo: Bool
    /// The pinned "now" from `-demoNow`, if any.
    var pinnedNow: Date?
    /// The screenshot scene from `-demoAppearance`, `-demoScene` and `-demoWindowSize`.
    var demoScene = DemoScene()

    /// The options of this process.
    static var current: LaunchOptions {
        parse(ProcessInfo.processInfo.arguments, timeZone: .current)
    }

    /// The clock the app runs on: the pinned instant, or the system clock.
    var timeSource: any TimeSource {
        if let pinnedNow {
            return FixedTimeSource(pinnedNow)
        }
        return SystemTimeSource()
    }

    static func parse(_ arguments: [String], timeZone: TimeZone) -> LaunchOptions {
        let isDemo = arguments.contains("-demo")
        var options = LaunchOptions(isDemo: isDemo)
        guard isDemo else { return options }
        options.demoScene = DemoScene.parse(arguments)
        if let flag = arguments.firstIndex(of: "-demoNow"), flag + 1 < arguments.count {
            options.pinnedNow = parseLocalDateTime(arguments[flag + 1], timeZone: timeZone)
        }
        return options
    }

    /// Parses `yyyy-MM-dd'T'HH:mm` as a wall-clock time in `timeZone`. Nil for anything else.
    static func parseLocalDateTime(_ text: String, timeZone: TimeZone) -> Date? {
        let halves = text.split(separator: "T", omittingEmptySubsequences: false)
        guard halves.count == 2 else { return nil }
        let day = halves[0].split(separator: "-", omittingEmptySubsequences: false).compactMap { Int($0) }
        let time = halves[1].split(separator: ":", omittingEmptySubsequences: false).compactMap { Int($0) }
        guard day.count == 3, time.count == 2, (1...12).contains(day[1]), (1...31).contains(day[2]),
            (0..<24).contains(time[0]), (0..<60).contains(time[1])
        else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = DateComponents(year: day[0], month: day[1], day: day[2], hour: time[0], minute: time[1])
        return calendar.date(from: parts)
    }

    /// The settings store for `-demo`: its own suite, emptied at every launch, so demo runs never see
    /// or change the user's settings.
    static func makeDemoDefaults() -> UserDefaults {
        let suiteName = "io.github.visaug36.Elenath.demo"
        // UserDefaults refuses only NSGlobalDomain and the app's own bundle ID as suite names.
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("The demo settings suite could not be created")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
