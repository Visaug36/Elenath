#if canImport(PDFKit) && canImport(Vision) && canImport(ImageIO)
    import CoreGraphics
    import Foundation
    import ImageIO
    import Vision
    // By class only: the module brings AppKit along, which ElenathCore never uses.
    import class PDFKit.PDFDocument
    import class PDFKit.PDFPage

    /// Reads PDFs with PDFKit, and pictures and scanned pages with Vision's text recognition (docs/ARCHITECTURE.md,
    /// "PDFs, pictures and event files"). Everything on the Mac: Vision's models are part of macOS.
    public struct SystemTextExtractor: TextExtractor {
        private static let log = CoreLog(category: "TextExtractor")

        public init() {}

        public func text(of url: URL, kind: FileTextKind) async throws -> ExtractedText? {
            switch kind {
            case .pdf:
                return try await Self.pdfText(url)
            case .picture:
                let limit = FileTextLimits.maximumPicturePixels
                guard let image = await Self.onUtilityQueue({ Self.decodedPicture(url, maximumPixels: limit) })
                else { return nil }
                return ExtractedText(pages: [try await Self.recognize(image)], isPaged: false)
            case .plainText:
                return nil
            }
        }

        // MARK: - PDFs

        /// PDFKit's text of each page, then text recognition for the pages that have none.
        private static func pdfText(_ url: URL) async throws -> ExtractedText? {
            let read: [String]? = await onUtilityQueue {
                guard let document = PDFDocument(url: url), !document.isLocked else { return nil }
                var pages: [String] = []
                var size = 0
                for index in 0..<min(document.pageCount, FileTextLimits.maximumPages) {
                    guard size < FileTextLimits.maximumTextBytes else { break }
                    let text = document.page(at: index)?.string ?? ""
                    pages.append(text)
                    size += text.utf8.count
                }
                return pages
            }
            guard var pages = read else { return nil }
            var scanned = 0
            for index in pages.indices where !pages[index].contains(where: { !$0.isWhitespace }) {
                guard scanned < FileTextLimits.maximumScannedPages else { break }
                try Task.checkCancellation()
                scanned += 1
                guard let image = await onUtilityQueue({ renderedPage(index + 1, of: url) }) else { continue }
                pages[index] = try await recognize(image)
            }
            return ExtractedText(pages: pages, isPaged: true).limited()
        }

        /// One page (1-based) drawn upright on white, its longer side about 3,000 pixels and at most `decodedSide`:
        /// enough for print of 8 points.
        private static func renderedPage(_ number: Int, of url: URL) -> SendableImage? {
            guard let document = CGPDFDocument(url as CFURL), let page = document.page(at: number) else { return nil }
            let box = page.getBoxRect(.cropBox)
            guard box.width >= 1, box.height >= 1 else { return nil }
            let turned = (Int(page.rotationAngle) % 180 + 180) % 180 != 0
            let size = turned ? CGSize(width: box.height, height: box.width) : box.size
            let longest = Double(min(3_000, FileTextLimits.decodedSide))
            let scale = min(longest / Double(max(size.width, size.height)), 8)
            let width = max(1, Int(Double(size.width) * scale))
            let height = max(1, Int(Double(size.height) * scale))
            guard
                let context = CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return nil }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            // The page's middle at the image's middle, turned clockwise as /Rotate says.
            context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
            context.rotate(by: -CGFloat(page.rotationAngle) * .pi / 180)
            context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            context.translateBy(x: -box.midX, y: -box.midY)
            context.drawPDFPage(page)
            return context.makeImage().map(SendableImage.init)
        }

        // MARK: - Pictures

        /// The picture upright, at most `decodedSide` on its longer side; nil when it isn't one ImageIO reads, is
        /// too small to hold text, or has more than `maximumPixels` (judged from its header, before anything is
        /// decoded).
        static func decodedPicture(_ url: URL, maximumPixels: Int) -> SendableImage? {
            let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary),
                CGImageSourceGetCount(source) > 0,
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions as CFDictionary)
                    as? [CFString: Any],
                let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                width >= 16, height >= 16
            else { return nil }
            let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
            guard !overflow, pixels <= maximumPixels else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: FileTextLimits.decodedSide,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(SendableImage.init)
        }

        // MARK: - Recognition

        /// The lines Vision recognizes, top to bottom.
        private static func recognize(_ image: SendableImage) async throws -> String {
            var request = RecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            do {
                let observations = try await request.perform(on: image.image, orientation: nil)
                return observations.map(\.transcript).joined(separator: "\n")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                log.error("Could not recognize text in a picture", private: String(describing: error))
                return ""
            }
        }

        /// Runs `work` on a utility queue, never on the caller's thread or the cooperative pool.
        private static func onUtilityQueue<Value: Sendable>(
            _ work: @escaping @Sendable () -> Value
        ) async -> Value {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: work())
                }
            }
        }
    }

    /// A decoded picture handed from the queue that made it to the recognizer. A `CGImage` never changes once made.
    struct SendableImage: @unchecked Sendable {
        let image: CGImage
    }
#endif
