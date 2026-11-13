import Carbon.HIToolbox

/// Carbon's virtual key codes (`kVK_*`) as `NSEvent.keyCode` reports them, for the keys Elenath recognizes
/// by position rather than by the character they type. Kept here so SwiftUI files needn't import Carbon.
enum VirtualKey {
    static let escape = UInt16(kVK_Escape)
    static let delete = UInt16(kVK_Delete)
    static let forwardDelete = UInt16(kVK_ForwardDelete)
    static let tab = UInt16(kVK_Tab)
}
