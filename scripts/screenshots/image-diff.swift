// Prints how many pixels differ between two images (any channel off by more than 2 of 255), or "size" when
// their sizes differ. Used by keep-unchanged.sh to tell real changes from rendering noise.
import CoreGraphics
import Foundation
import ImageIO

func rgba(_ path: String) -> (width: Int, height: Int, bytes: [UInt8])? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }
    let width = image.width
    let height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
        guard
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    return drawn ? (width: width, height: height, bytes: bytes) : nil
}

guard CommandLine.arguments.count == 3,
    let first = rgba(CommandLine.arguments[1]),
    let second = rgba(CommandLine.arguments[2])
else {
    FileHandle.standardError.write(Data("usage: image-diff <a.png> <b.png>\n".utf8))
    exit(2)
}
guard first.width == second.width, first.height == second.height else {
    print("size")
    exit(0)
}
var changed = 0
for pixel in stride(from: 0, to: first.bytes.count, by: 4) {
    for channel in 0..<4 where abs(Int(first.bytes[pixel + channel]) - Int(second.bytes[pixel + channel])) > 2 {
        changed += 1
        break
    }
}
print(changed)
