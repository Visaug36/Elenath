#if canImport(NaturalLanguage)
    import Foundation
    import NaturalLanguage

    /// The real embedder: Apple's contextual embeddings (`NLContextualEmbedding`), one model per script, each
    /// text's vector the mean of its token vectors, normalized (docs/ARCHITECTURE.md, "Meaning › The embedder").
    ///
    /// A model counts only once its assets are on the Mac (`hasAvailableAssets`). For text in a script without
    /// one, `requestModel(for:)` asks the system to fetch it (`requestAssets`), once per launch; until it
    /// arrives that text is found by keyword search alone.
    public actor ContextualEmbedder: Embedder {
        private var embeddings: [String: NLContextualEmbedding] = [:]
        private var loaded: Set<String> = []
        private var requested: Set<String> = []
        private let log = CoreLog(category: "ContextualEmbedder")

        public init() {}

        public func models() async -> [EmbeddingModel] {
            Script.all.compactMap { script in
                guard let embedding = embedding(for: script), embedding.hasAvailableAssets else { return nil }
                return EmbeddingModel(
                    stamp: EmbedderStamp(identifier: embedding.modelIdentifier, revision: embedding.revision),
                    script: script, dimension: embedding.dimension)
            }
        }

        public func requestModel(for script: String) async {
            guard !requested.contains(script), let embedding = embedding(for: script), !embedding.hasAvailableAssets
            else { return }
            requested.insert(script)
            let log = log
            embedding.requestAssets { result, error in
                if error != nil || result != .available {
                    log.notice("An embedding model isn't on this Mac yet; its text is found by keyword search")
                }
            }
        }

        public func vectors(for texts: [String], with model: EmbeddingModel) async throws -> [[Float]?] {
            guard let embedding = embedding(for: model.script), embedding.hasAvailableAssets,
                embedding.modelIdentifier == model.stamp.identifier, embedding.revision == model.stamp.revision
            else { return texts.map { _ in nil } }
            if !loaded.contains(model.script) {
                try embedding.load()
                loaded.insert(model.script)
            }
            return texts.map { text in Self.vector(of: text, with: embedding) }
        }

        public func rest() async {
            for script in loaded {
                embeddings[script]?.unload()
            }
            loaded = []
        }

        // MARK: - Private

        private func embedding(for script: String) -> NLContextualEmbedding? {
            if let embedding = embeddings[script] {
                return embedding
            }
            guard let nlScript = Self.nlScript(for: script), let embedding = NLContextualEmbedding(script: nlScript)
            else { return nil }
            embeddings[script] = embedding
            return embedding
        }

        /// The mean of the text's token vectors, normalized; nil when the model reads nothing in it.
        private static func vector(of text: String, with embedding: NLContextualEmbedding) -> [Float]? {
            guard !text.isEmpty, let result = try? embedding.embeddingResult(for: text, language: nil) else {
                return nil
            }
            var sum = [Double](repeating: 0, count: embedding.dimension)
            var count = 0
            result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
                if vector.count == sum.count {
                    for index in vector.indices {
                        sum[index] += vector[index]
                    }
                    count += 1
                }
                return true
            }
            guard count > 0 else { return nil }
            return VectorMath.normalized(sum.map { Float($0 / Double(count)) })
        }

        private static func nlScript(for script: String) -> NLScript? {
            switch script {
            case Script.latin: .latin
            case Script.cyrillic: .cyrillic
            case Script.greek: .greek
            case Script.arabic: .arabic
            case Script.hebrew: .hebrew
            case Script.devanagari: .devanagari
            case Script.thai: .thai
            case Script.korean: .korean
            case Script.japanese: .japanese
            case Script.chinese: .simplifiedChinese
            default: nil
            }
        }
    }
#endif
