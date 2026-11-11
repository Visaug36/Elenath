#if canImport(os)
    import os
#endif

/// Logging for ElenathCore. On Apple platforms it writes to the unified log (`os.Logger`); elsewhere it
/// does nothing.
///
/// A message is a fixed string. The only dynamic value is `detail`, and it is always logged as private,
/// so a note's title, its text, a file name or a prompt can't end up readable in a log by accident.
public struct CoreLog: Sendable {
    public static let subsystem = "io.github.visaug36.Elenath"

    #if canImport(os)
        private let logger: Logger
    #endif

    public init(category: String) {
        #if canImport(os)
            logger = Logger(subsystem: CoreLog.subsystem, category: category)
        #endif
    }

    public func notice(_ message: StaticString) {
        #if canImport(os)
            logger.notice("\(message.description, privacy: .public)")
        #endif
    }

    public func error(_ message: StaticString) {
        #if canImport(os)
            logger.error("\(message.description, privacy: .public)")
        #endif
    }

    /// Logs `message` with a detail that stays private (an error's description, a file name).
    public func error(_ message: StaticString, private detail: String) {
        #if canImport(os)
            logger.error("\(message.description, privacy: .public): \(detail, privacy: .private)")
        #endif
    }
}
