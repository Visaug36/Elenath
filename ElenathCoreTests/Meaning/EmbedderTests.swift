import ElenathCore
import Foundation
import Testing

/// Vectors as the index keeps them, the script that picks a model, and the stand-in embedder the other
/// tests rely on.
struct EmbedderTests {
    @Test func normalizedVectorsHaveLengthOne() throws {
        let vector = try #require(VectorMath.normalized([3, 4]))
        #expect(abs(VectorMath.dot(vector, vector) - 1) < 1e-6)
        #expect(vector == [0.6, 0.8])
        #expect(VectorMath.normalized([0, 0]) == nil)
        #expect(VectorMath.normalized([]) == nil)
        #expect(VectorMath.normalized([1, .nan]) == nil)
        #expect(VectorMath.normalized([1, .infinity]) == nil)
    }

    @Test func dotProductsAndMeans() {
        #expect(VectorMath.dot([1, 2, 3], [4, 5, 6]) == 32)
        #expect(VectorMath.dot([1, 2], [1, 2, 3]) == 0)
        #expect(VectorMath.mean([[1, 3], [3, 5]]) == [2, 4])
        #expect(VectorMath.mean([]) == nil)
        #expect(VectorMath.mean([[1], [1, 2]]) == nil)
    }

    @Test func storedBytesRoundTripAndAreChecked() {
        let vector: [Float] = [0.25, -1.5, 3e-8, 1e30]
        let data = VectorMath.encode(vector)
        #expect(data.count == 16)
        #expect(data.prefix(4) == Data([0x00, 0x00, 0x80, 0x3E]))  // 0.25, little-endian
        #expect(VectorMath.decode(data, dimension: 4) == vector)
        #expect(VectorMath.decode(data, dimension: 3) == nil)
        #expect(VectorMath.decode(data.prefix(15), dimension: 4) == nil)
        #expect(VectorMath.decode(VectorMath.encode([1, .nan]), dimension: 2) == nil)
        #expect(VectorMath.decode(Data(), dimension: 0) == nil)
    }

    @Test func theScriptOfMostLettersPicksTheModel() {
        #expect(Script.dominant(in: "Torque is a force that turns things.") == Script.latin)
        #expect(Script.dominant(in: "Ça déménage, Größe, ñandú") == Script.latin)
        #expect(Script.dominant(in: "Момент силы и угловой момент") == Script.cyrillic)
        #expect(Script.dominant(in: "Ροπή δύναμης") == Script.greek)
        #expect(Script.dominant(in: "عزم الدوران") == Script.arabic)
        #expect(Script.dominant(in: "מומנט כוח") == Script.hebrew)
        #expect(Script.dominant(in: "बल आघूर्ण") == Script.devanagari)
        #expect(Script.dominant(in: "แรงบิด") == Script.thai)
        #expect(Script.dominant(in: "토크는 회전력이다") == Script.korean)
        #expect(Script.dominant(in: "力矩是使物体转动的力") == Script.chinese)
        // Kana make a text Japanese, even with more kanji.
        #expect(Script.dominant(in: "力学的な回転力の説明です") == Script.japanese)
        #expect(Script.dominant(in: "Lecture 7: 力 and torque") == Script.latin)
        #expect(Script.dominant(in: "12:30 — 4 × 5 = 20 !") == nil)
        #expect(Script.dominant(in: "") == nil)
    }

    @Test func aTextGetsTheModelOfItsScriptOrNone() async {
        let embedder = HashingEmbedder(scripts: [Script.latin, Script.cyrillic])
        let models = await embedder.models()
        #expect(embedder.model(for: "Physics lecture", among: models)?.script == Script.latin)
        #expect(embedder.model(for: "Лекция по физике", among: models)?.script == Script.cyrillic)
        #expect(embedder.model(for: "物理の講義", among: models) == nil)
        #expect(embedder.model(for: "2026", among: models) == nil)
    }

    @Test func theStandInEmbedderPutsTextsThatShareWordsClose() async throws {
        let embedder = HashingEmbedder()
        let model = try #require(await embedder.models().first)
        let vectors = try await embedder.vectors(
            for: [
                "torque and angular momentum", "angular momentum is conserved without torque", "a recipe for bread",
                "!!",
            ],
            with: model)
        let torque = try #require(vectors[0])
        let momentum = try #require(vectors[1])
        let bread = try #require(vectors[2])
        #expect(VectorMath.dot(torque, momentum) > VectorMath.dot(torque, bread) + 0.3)
        #expect(vectors[3] == nil)
    }
}
