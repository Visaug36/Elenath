import AppKit
import ElenathCore
import SwiftUI

extension View {
    /// Dragging the block moves its event (`TimeGridDragMath.move`): the grid's preview shows where it
    /// would land and the block is dimmed meanwhile; letting go saves it (for a repeating event after "This
    /// Event Only" / "All Future Events"). A click without moving still reaches `eventInteraction`, so apply
    /// this before it. Does nothing while the library can't be edited.
    func eventBlockDrag(item: DayLayout.Item, context: TimeGridDragContext) -> some View {
        modifier(EventBlockDragModifier(item: item, context: context))
    }

    /// With the block focused, ⌥↑ / ⌥↓ move its event 15 minutes and ⌥⇧↑ / ⌥⇧↓ move its end, through
    /// the same path as a drag (a repeating event asks first). VoiceOver gets the same four changes as
    /// actions. Apply after `eventInteraction`, which makes the block focusable.
    func eventBlockKeyboardMoves(occurrence: Occurrence, context: TimeGridDragContext) -> some View {
        modifier(EventBlockKeyboardModifier(occurrence: occurrence, context: context))
    }
}

private struct EventBlockDragModifier: ViewModifier {
    @Environment(CalendarModel.self) private var model
    @GestureState private var isDragging = false
    let item: DayLayout.Item
    let context: TimeGridDragContext

    func body(content: Content) -> some View {
        let isActive = context.state.activeID == item.occurrence.id
        content
            .opacity(isActive ? 0.4 : 1)
            .gesture(drag, including: model.canEdit ? .all : .subviews)
            .onChange(of: isDragging) { _, dragging in
                if !dragging {
                    dragStopped()
                }
            }
            .onDisappear {
                dragStopped()
            }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 4)
            .updating($isDragging) { _, state, _ in
                state = true
            }
            .onChanged { value in
                guard model.canEdit else { return }
                let preview = TimeGridDragMath.move(item, by: value.translation, context: context, math: model.math)
                context.state.track(preview)
            }
            .onEnded { value in
                let preview = TimeGridDragMath.move(item, by: value.translation, context: context, math: model.math)
                context.state.propose(preview.change, preview: preview, model: model)
            }
    }

    /// A drag that stopped without being saved or asked about (cancelled, or the block went away) leaves no
    /// preview behind.
    private func dragStopped() {
        let state = context.state
        if state.activeID == item.occurrence.id, state.pendingChange == nil {
            state.cancel()
        }
    }
}

/// The bottom edge of a block (6 pt) on the segment that holds the event's end: dragging it changes when
/// the event ends (`TimeGridDragMath.resize`), and over it the pointer is the up-down resize arrow. A click
/// on it still selects the block. Shown only while the library can be edited.
struct EventBlockResizeHandle: View {
    static let height: CGFloat = 6

    @Environment(CalendarModel.self) private var model
    @State private var isHovering = false
    @GestureState private var isResizing = false
    let item: DayLayout.Item
    let context: TimeGridDragContext

    var body: some View {
        let showsResizeCursor = isHovering || isResizing
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: Self.height)
            .contentShape(Rectangle())
            .onHover { inside in
                isHovering = inside
            }
            .gesture(resize)
            .onChange(of: showsResizeCursor) { _, shows in
                if shows {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onChange(of: isResizing) { _, resizing in
                if !resizing {
                    resizeStopped()
                }
            }
            .onDisappear {
                if showsResizeCursor {
                    NSCursor.pop()
                }
                resizeStopped()
            }
            .accessibilityHidden(true)
    }

    private var resize: some Gesture {
        DragGesture(minimumDistance: 2)
            .updating($isResizing) { _, state, _ in
                state = true
            }
            .onChanged { value in
                guard model.canEdit else { return }
                let height = value.translation.height
                context.state.track(TimeGridDragMath.resize(item, by: height, context: context, math: model.math))
            }
            .onEnded { value in
                let height = value.translation.height
                let preview = TimeGridDragMath.resize(item, by: height, context: context, math: model.math)
                context.state.propose(preview.change, preview: preview, model: model)
            }
    }

    private func resizeStopped() {
        let state = context.state
        if state.activeID == item.occurrence.id, state.pendingChange == nil {
            state.cancel()
        }
    }
}

private struct EventBlockKeyboardModifier: ViewModifier {
    @Environment(CalendarModel.self) private var model
    let occurrence: Occurrence
    let context: TimeGridDragContext

    func body(content: Content) -> some View {
        content
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                handle(press)
            }
            .accessibilityAction(named: Text("Move 15 Minutes Earlier")) {
                step(by: -TimeGridDragMath.snapMinutes, changingEnd: false)
            }
            .accessibilityAction(named: Text("Move 15 Minutes Later")) {
                step(by: TimeGridDragMath.snapMinutes, changingEnd: false)
            }
            .accessibilityAction(named: Text("Make 15 Minutes Shorter")) {
                step(by: -TimeGridDragMath.snapMinutes, changingEnd: true)
            }
            .accessibilityAction(named: Text("Make 15 Minutes Longer")) {
                step(by: TimeGridDragMath.snapMinutes, changingEnd: true)
            }
    }

    /// ⌥↑ / ⌥↓ and ⌥⇧↑ / ⌥⇧↓; other arrows are left to the calendar and the scroll view.
    private func handle(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.contains(.option), press.modifiers.isDisjoint(with: [.command, .control]) else {
            return .ignored
        }
        let minutes = press.key == .upArrow ? -TimeGridDragMath.snapMinutes : TimeGridDragMath.snapMinutes
        step(by: minutes, changingEnd: press.modifiers.contains(.shift))
        return .handled
    }

    /// Moves the event (or its end) by `minutes`; beeps when it can't. Starts from the occurrence as the
    /// library has it now, so a held key keeps moving it even before the block has redrawn.
    private func step(by minutes: Int, changingEnd: Bool) {
        guard model.canEdit, context.state.pendingChange == nil else {
            NSSound.beep()
            return
        }
        let current = model.occurrence(id: occurrence.id) ?? occurrence
        let change: EventTimeChange?
        if changingEnd {
            change = TimeGridDragMath.endMoved(current, byMinutes: minutes)
        } else {
            change = TimeGridDragMath.moved(current, byMinutes: minutes)
        }
        guard let change else {
            NSSound.beep()
            return
        }
        let preview = TimeGridDragMath.preview(of: change, column: context.column, day: context.day, math: model.math)
        context.state.propose(change, preview: preview, model: model)
    }
}
