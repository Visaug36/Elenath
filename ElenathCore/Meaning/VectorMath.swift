import Foundation

#if canImport(Accelerate)
    import Accelerate
#endif

/// Vectors as the index keeps them: normalized Float32s, stored as little-endian bytes, compared by their dot
/// product (their cosine, since they are normalized).
public enum VectorMath {
    /// `vector` scaled to length 1, or nil when it has no length or holds a value that isn't finite.
    public static func normalized(_ vector: [Float]) -> [Float]? {
        guard !vector.isEmpty, vector.allSatisfy(\.isFinite) else { return nil }
        let length = dot(vector, vector).squareRoot()
        guard length > 0, length.isFinite else { return nil }
        return vector.map { $0 / length }
    }

    /// The mean of `vectors` (all of one length), or nil for none.
    public static func mean(_ vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first, vectors.allSatisfy({ $0.count == first.count }) else { return nil }
        var sum = [Float](repeating: 0, count: first.count)
        for vector in vectors {
            for index in vector.indices {
                sum[index] += vector[index]
            }
        }
        let count = Float(vectors.count)
        return sum.map { $0 / count }
    }

    /// The dot product of two vectors of one length (0 when the lengths differ).
    public static func dot(_ first: [Float], _ second: [Float]) -> Float {
        guard first.count == second.count else { return 0 }
        return first.withUnsafeBufferPointer { a in
            second.withUnsafeBufferPointer { b in dot(a, b) }
        }
    }

    public static func dot(_ first: UnsafeBufferPointer<Float>, _ second: UnsafeBufferPointer<Float>) -> Float {
        let count = min(first.count, second.count)
        guard count > 0, let a = first.baseAddress, let b = second.baseAddress else { return 0 }
        #if canImport(Accelerate)
            var result: Float = 0
            vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(count))
            return result
        #else
            var result: Float = 0
            for index in 0..<count {
                result += a[index] * b[index]
            }
            return result
        #endif
    }

    /// The bytes the index stores: each value as a little-endian Float32.
    public static func encode(_ vector: [Float]) -> Data {
        var data = Data(capacity: vector.count * 4)
        for value in vector {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// A vector from stored bytes, or nil when they aren't `dimension` finite Float32s.
    public static func decode(_ data: Data, dimension: Int) -> [Float]? {
        guard dimension > 0, data.count == dimension * 4 else { return nil }
        var vector = [Float](repeating: 0, count: dimension)
        data.withUnsafeBytes { raw in
            for index in 0..<dimension {
                let bits = raw.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)
                vector[index] = Float(bitPattern: UInt32(littleEndian: bits))
            }
        }
        return vector.allSatisfy(\.isFinite) ? vector : nil
    }
}
