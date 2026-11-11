// Prints "x,y,width,height" (global, top-left origin, as `screencapture -R` expects) for the largest
// on-screen window owned by the given process ID. Used by capture.sh to screenshot the -demo app.
import CoreGraphics
import Foundation

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let windows = (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []

// `window-bounds --list` prints every window, on screen or not, for debugging a failed capture.
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--list" {
    let all = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
    for window in all {
        let owner = window[kCGWindowOwnerName as String] as? String ?? "?"
        let pid = window[kCGWindowOwnerPID as String] as? Int32 ?? -1
        let layer = window[kCGWindowLayer as String] as? Int ?? -1
        let name = window[kCGWindowName as String] as? String ?? ""
        let onScreen = window[kCGWindowIsOnscreen as String] as? Bool ?? false
        let rect = (window[kCGWindowBounds as String] as? NSDictionary)
            .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
        print("\(owner) pid=\(pid) layer=\(layer) onScreen=\(onScreen) name=\"\(name)\" \(rect)")
    }
    exit(0)
}

guard CommandLine.arguments.count == 2, let pid = Int32(CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("usage: window-bounds <pid> | --list\n".utf8))
    exit(2)
}

func bounds(of window: [String: Any]) -> CGRect? {
    guard let dictionary = window[kCGWindowBounds as String] as? NSDictionary else { return nil }
    return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
}

let owned = windows.compactMap { window -> CGRect? in
    guard (window[kCGWindowOwnerPID as String] as? Int32) == pid,
        (window[kCGWindowLayer as String] as? Int) == 0
    else { return nil }
    return bounds(of: window)
}

guard let largest = owned.max(by: { $0.width * $0.height < $1.width * $1.height }) else {
    FileHandle.standardError.write(Data("no window for pid \(pid)\n".utf8))
    exit(1)
}
print("\(Int(largest.minX)),\(Int(largest.minY)),\(Int(largest.width)),\(Int(largest.height))")
