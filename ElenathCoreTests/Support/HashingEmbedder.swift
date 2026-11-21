import ElenathCore
import Foundation

/// A stand-in for the real embedder: each word (lowercased letters and digits) is hashed into one of
/// `dimension` slots with a sign, and the sum is normalized. Texts that share words come out close, the same
/// on every machine, without a model.
struct HashingEmbedder: Embedder {
    var dimension = 64
    var scripts: [String] = [Script.latin]
    var revision = 1

    func models() async -> [EmbeddingModel] {
        scripts.map {
            EmbeddingModel(
                stamp: EmbedderStamp(identifier: "hashing-\($0)", revision: revision), script: $0, dimension: dimension)
        }
    }

    func vectors(for texts: [String], with model: EmbeddingModel) async throws -> [[Float]?] {
        texts.map { text in
            var vector = [Float](repeating: 0, count: model.dimension)
            for word in Self.words(in: text) {
                let hash = Self.fnv1a(word)
                vector[Int(hash % UInt64(model.dimension))] += hash >> 63 == 0 ? 1 : -1
            }
            return VectorMath.normalized(vector)
        }
    }

    static func words(in text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    static func fnv1a(_ word: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in word.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}
