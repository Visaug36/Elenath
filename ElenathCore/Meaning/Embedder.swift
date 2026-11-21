import Foundation

/// Which model made a vector, and which version of it: the index is stamped with it and makes a model's
/// vectors again when it changes (a macOS update).
public struct EmbedderStamp: Hashable, Codable, Sendable {
    public var identifier: String
    public var revision: Int

    public init(identifier: String, revision: Int) {
        self.identifier = identifier
        self.revision = revision
    }

    /// "identifier@revision", as the index stores it.
    public var key: String { "\(identifier)@\(revision)" }
}

/// One model the embedder has on this Mac now, for one script.
public struct EmbeddingModel: Hashable, Codable, Sendable {
    public var stamp: EmbedderStamp
    /// The script it reads, as an ISO 15924 code ("Latn", "Cyrl", "Hans"…; `Script`).
    public var script: String
    /// The length of its vectors.
    public var dimension: Int

    public init(stamp: EmbedderStamp, script: String, dimension: Int) {
        self.stamp = stamp
        self.script = script
        self.dimension = dimension
    }
}

/// Turns text into vectors that are close when the texts mean similar things (docs/ARCHITECTURE.md,
/// "Meaning › The embedder"). The real one is `ContextualEmbedder`; tests use a fake.
public protocol Embedder: Sendable {
    /// The models this embedder has on this Mac right now. Asked at run time, never assumed: a script
    /// without a model, or whose model isn't on the Mac yet, is left to keyword search.
    func models() async -> [EmbeddingModel]
    /// One normalized vector per text, or nil for a text the model couldn't read.
    func vectors(for texts: [String], with model: EmbeddingModel) async throws -> [[Float]?]
    /// Asks the system for the model of `script` (ISO 15924), for text in it that has none yet. Its assets
    /// arrive in the background; `models()` lists it once they are on the Mac.
    func requestModel(for script: String) async
    /// Lets go of loaded models when indexing is done; they load again on the next question.
    func rest() async
}

extension Embedder {
    public func requestModel(for script: String) async {}
    public func rest() async {}

    /// The model that reads `text`: the one for its main script, if there is one.
    public func model(for text: String, among models: [EmbeddingModel]) -> EmbeddingModel? {
        guard let script = Script.dominant(in: text) else { return nil }
        return models.first { $0.script == script }
    }
}

/// The scripts Elenath tells apart to pick a model (ISO 15924 codes), by the Unicode blocks of the letters in a
/// text. Linear in the text; looks at the first `sampleLength` characters only.
public enum Script {
    public static let latin = "Latn"
    public static let cyrillic = "Cyrl"
    public static let greek = "Grek"
    public static let arabic = "Arab"
    public static let hebrew = "Hebr"
    public static let devanagari = "Deva"
    public static let thai = "Thai"
    public static let korean = "Kore"
    public static let japanese = "Jpan"
    public static let chinese = "Hans"

    public static let all = [latin, cyrillic, greek, arabic, hebrew, devanagari, thai, korean, japanese, chinese]

    /// How many characters of a text decide its script.
    static let sampleLength = 2_000

    /// The script most of the text's letters are in, or nil when it has none of these. Kana make a text
    /// Japanese even among more Chinese characters, as Japanese is written.
    public static func dominant(in text: String) -> String? {
        var counts: [String: Int] = [:]
        var seen = 0
        for scalar in text.unicodeScalars {
            seen += 1
            if seen > sampleLength {
                break
            }
            // Letters only: "×" and "÷" sit among the Latin ones.
            if scalar.properties.isAlphabetic, let script = script(of: scalar) {
                counts[script, default: 0] += 1
            }
        }
        if counts[japanese, default: 0] > 0, counts[chinese] != nil {
            counts[japanese, default: 0] += counts[chinese, default: 0]
            counts[chinese] = nil
        }
        // The most letters wins; on a tie, the order of `all`.
        return all.filter { counts[$0, default: 0] > 0 }.max { counts[$0, default: 0] < counts[$1, default: 0] }
    }

    private static func script(of scalar: Unicode.Scalar) -> String? {
        switch scalar.value {
        case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F, 0x1E00...0x1EFF: latin
        case 0x370...0x3FF, 0x1F00...0x1FFF: greek
        case 0x400...0x52F: cyrillic
        case 0x590...0x5FF: hebrew
        case 0x600...0x6FF, 0x750...0x77F, 0xFB50...0xFDFF, 0xFE70...0xFEFF: arabic
        case 0x900...0x97F: devanagari
        case 0xE00...0xE7F: thai
        case 0x1100...0x11FF, 0xAC00...0xD7AF: korean
        case 0x3040...0x30FF, 0x31F0...0x31FF: japanese
        case 0x4E00...0x9FFF, 0x3400...0x4DBF: chinese
        default: nil
        }
    }
}
