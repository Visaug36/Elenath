import AppKit
import ElenathCore
import Foundation
import FoundationModels
import NaturalLanguage

/// The report for the checks only a real Mac can make (docs/ARCHITECTURE.md, "What CI can't check"):
/// whether the on-device model answers from the sandboxed, ad-hoc-signed app, whether the embedding
/// assets arrive without a network entitlement, and whether the folder's bookmark survived an update.
///
/// The report names no note, title or file: it can be copied and sent as it is.
enum Diagnostics {
    @MainActor
    static func run(model: AppModel) async -> String {
        var lines: [String] = []
        lines.append("Elenath diagnostics, \(Date.now.formatted(.iso8601))")
        lines.append("")
        lines.append("Elenath: \(SavedFolder.currentVersion)\(model.isDemo ? " (demo)" : "")")
        lines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("Mac: \(sysctlString("hw.model") ?? "?"), \(sysctlString("machdep.cpu.brand_string") ?? "?")")
        lines.append("Memory: \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB")
        let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        lines.append("App Sandbox: \(sandboxed ? "on" : "off")")
        lines.append("")
        lines.append("Library")
        lines.append("  Folder bookmark: \(model.bookmarkStatus)")
        lines.append("  State: \(String(describing: model.state))\(model.isReadOnly ? ", read-only" : "")")
        lines.append("  Spaces: \(model.spaces.count), sealed: \(model.spaces.filter(\.isSealed).count)")
        if let services = model.services {
            let notes =
                (try? await services.retrieval.search(SearchQuery(text: "", limit: 100_000), from: .everywhere))?.count
            lines.append("  Notes indexed (spaces that mix): \(notes.map(String.init) ?? "?")")
            lines.append("  Inbox items: \((try? await services.retrieval.inboxCount()) ?? 0)")
        }
        lines.append(
            "  SQLite: \(IndexDiagnostics.sqliteVersion), full-text search: \(IndexDiagnostics.hasFullTextSearch ? "yes" : "no")"
        )
        lines.append("")
        lines += await languageModelReport()
        lines.append("")
        lines += await embeddingReport()
        return lines.joined(separator: "\n")
    }

    // MARK: - The on-device model

    @MainActor
    private static func languageModelReport() async -> [String] {
        var lines = ["Apple Intelligence (the on-device model Nano bot will use)"]
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            lines.append("  Availability: available")
        case .unavailable(let reason):
            lines.append("  Availability: unavailable, \(describe(reason))")
            return lines
        }
        lines.append("  Context size: \(model.contextSize) tokens")
        lines.append("  Supports English: \(model.supportsLocale(Locale(identifier: "en_US")) ? "yes" : "no")")
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: "Answer with the single word OK.")
            let answer = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append("  Test answer: \"\(answer.prefix(40))\" in \(format(clock.now - start))")
        } catch {
            lines.append("  Test answer: failed after \(format(clock.now - start)): \(String(describing: error))")
        }
        return lines
    }

    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible: "this Mac can't run Apple Intelligence"
        case .appleIntelligenceNotEnabled: "Apple Intelligence is turned off in System Settings"
        case .modelNotReady: "the model is still downloading"
        @unknown default: "\(reason)"
        }
    }

    // MARK: - Embeddings

    private static func embeddingReport() async -> [String] {
        var lines = ["Meaning search (the embedding model, for version 0.2)"]
        guard let embedding = NLContextualEmbedding(language: .english) else {
            lines.append("  English: no model on this Mac")
            return lines
        }
        lines.append(
            "  Model: \(embedding.modelIdentifier), revision \(embedding.revision), \(embedding.dimension) dimensions")
        lines.append("  Assets on this Mac: \(embedding.hasAvailableAssets ? "yes" : "no")")
        if !embedding.hasAvailableAssets {
            do {
                let result = try await embedding.requestAssets()
                switch result {
                case .available: lines.append("  Requesting assets: they arrived")
                case .notAvailable: lines.append("  Requesting assets: not available")
                case .error: lines.append("  Requesting assets: an error")
                @unknown default: lines.append("  Requesting assets: \(result.rawValue)")
                }
            } catch {
                lines.append("  Requesting assets failed: \(String(describing: error))")
            }
        }
        let clock = ContinuousClock()
        let start = clock.now
        do {
            try embedding.load()
            let result = try embedding.embeddingResult(
                for: "Rotational motion and the moment of inertia.", language: .english)
            lines.append("  Test sentence: \(result.sequenceLength) tokens embedded in \(format(clock.now - start))")
            embedding.unload()
        } catch {
            lines.append("  Test sentence failed: \(String(describing: error))")
        }
        return lines
    }

    // MARK: - Helpers

    private static func format(_ duration: Duration) -> String {
        let milliseconds = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        return "\(Int(milliseconds.rounded())) ms"
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
