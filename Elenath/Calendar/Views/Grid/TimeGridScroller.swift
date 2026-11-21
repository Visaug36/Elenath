import AppKit
import SwiftUI

/// A request to scroll the time grid so content y `offset` is at the top of the scroll view. `serial` changes
/// with every request, so asking for the same hour twice scrolls twice.
struct TimeGridScrollRequest: Equatable {
    var offset: CGFloat
    var serial: Int
}

/// Scrolls the enclosing `NSScrollView` (the one behind SwiftUI's `ScrollView`) to a request's offset, once
/// per request. `ScrollViewReader` can't do this here: the grid's hour targets are nested inside the one child
/// of a lazy, pinned-header stack, where its proxy doesn't find them.
///
/// The scroll waits (briefly) until the view is in a window and the grid has been laid out, so a request made
/// as the grid first appears isn't lost.
struct TimeGridScroller: NSViewRepresentable {
    let request: TimeGridScrollRequest?

    func makeNSView(context: Context) -> TimeGridScrollerView {
        TimeGridScrollerView()
    }

    func updateNSView(_ view: TimeGridScrollerView, context: Context) {
        view.request = request
    }
}

final class TimeGridScrollerView: NSView {
    /// How often, and how long, to wait for the first layout before giving up on a request.
    private static let retryInterval: Duration = .milliseconds(50)
    private static let maxAttempts = 40

    var request: TimeGridScrollRequest? {
        didSet {
            guard request != oldValue else { return }
            scheduleScroll()
        }
    }

    private var appliedSerial: Int?
    private var isScheduled = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleScroll()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    /// Scrolls after the current layout pass, retrying briefly until the document has its height.
    private func scheduleScroll() {
        guard !isScheduled, let request, request.serial != appliedSerial else { return }
        isScheduled = true
        Task { @MainActor [weak self] in
            for _ in 0..<Self.maxAttempts {
                guard let self else { return }
                if self.applyScroll() {
                    break
                }
                try? await Task.sleep(for: Self.retryInterval)
            }
            self?.isScheduled = false
        }
    }

    /// Applies the newest request. False while there's nothing to scroll yet (no window or no layout).
    private func applyScroll() -> Bool {
        guard let request, request.serial != appliedSerial else { return true }
        guard window != nil, let scrollView = enclosingScrollView, let document = scrollView.documentView else {
            return false
        }
        let clip = scrollView.contentView
        // Until the grid is laid out at full height, a scroll would be cut short.
        guard document.frame.height >= TimeGridGeometry.gridHeight, clip.bounds.height > 0 else { return false }
        // SwiftUI's document view is flipped (y grows downwards); anything else is left alone.
        guard document.isFlipped else {
            appliedSerial = request.serial
            return true
        }
        // The content starts under the toolbar: scrolled to the top, the clip view is at minus its top inset.
        let insets = clip.contentInsets
        let top = -insets.top
        let bottom = max(top, document.frame.height - clip.bounds.height + insets.bottom)
        let y = min(max(top, request.offset - insets.top), bottom)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clip)
        appliedSerial = request.serial
        return true
    }
}
