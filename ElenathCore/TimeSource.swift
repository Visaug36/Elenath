import Foundation

/// The single source of "now" for Elenath's logic, so date math can be tested against a fixed clock.
public protocol TimeSource: Sendable {
    var now: Date { get }
}

/// Reads the system clock.
public struct SystemTimeSource: TimeSource {
    public init() {}

    public var now: Date { Date() }
}

/// Always reports the same instant. Used by tests and by the `-demo` launch argument.
public struct FixedTimeSource: TimeSource {
    public var now: Date

    public init(_ now: Date) {
        self.now = now
    }
}
