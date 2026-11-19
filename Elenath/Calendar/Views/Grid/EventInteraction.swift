import ElenathCore
import SwiftUI

/// The popover an event in the calendar shows: its details (click, Return) or its editor (double-click,
/// Edit in the details, or Quick Add's ⌘↩). Switching kinds replaces one popover with the other.
enum EventPopoverKind: Hashable, Identifiable {
    case details
    case editor

    var id: Self { self }
}

extension View {
    /// Makes an event in the calendar (a block, an all-day bar or a month row) selectable and openable.
    ///
    /// A click selects it and shows its details in a popover; a double-click opens the editor instead. It
    /// takes keyboard focus (focusing it selects it) and Return shows the details. VoiceOver's default
    /// action shows the details and an "Edit" action opens the editor. With `handlesPendingEditor`, it
    /// also opens the editor when Quick Add's ⌘↩ asks for this occurrence; only one view per occurrence
    /// should, e.g. the first segment of an event drawn across two days. When `claimsFocus` returns true
    /// as the view appears, it takes keyboard focus (a block that a drag or ⌥-arrow key just moved).
    func eventInteraction(
        occurrence: Occurrence,
        arrowEdge: Edge,
        handlesPendingEditor: Bool,
        claimsFocus: (@MainActor () -> Bool)? = nil
    ) -> some View {
        let interaction = EventInteractionModifier(
            occurrence: occurrence, arrowEdge: arrowEdge, handlesPendingEditor: handlesPendingEditor,
            claimsFocus: claimsFocus)
        return modifier(interaction)
    }
}

private struct EventInteractionModifier: ViewModifier {
    @Environment(CalendarModel.self) private var model
    @FocusState private var isFocused: Bool
    @State private var popover: EventPopoverKind? = nil
    let occurrence: Occurrence
    let arrowEdge: Edge
    let handlesPendingEditor: Bool
    let claimsFocus: (@MainActor () -> Bool)?

    func body(content: Content) -> some View {
        content
            .onTapGesture {
                handleClick()
            }
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .onKeyPress(.return) {
                showDetails()
                return .handled
            }
            .onChange(of: isFocused) { _, focused in
                if focused {
                    model.selectedOccurrenceID = occurrence.id
                }
            }
            .accessibilityAction(.default) {
                showDetails()
            }
            .accessibilityAction(named: Text("Edit")) {
                showEditor()
            }
            .popover(item: $popover, arrowEdge: arrowEdge) { kind in
                popoverContent(kind)
            }
            .onAppear {
                openPendingEditor()
                openPendingDetails()
                takeFocusIfClaimed()
            }
            .onChange(of: model.pendingEditorOccurrenceID) {
                openPendingEditor()
            }
            .onChange(of: model.pendingDetailsOccurrenceID) {
                openPendingDetails()
            }
    }

    @ViewBuilder private func popoverContent(_ kind: EventPopoverKind) -> some View {
        switch kind {
        case .details:
            EventDetailsView(
                occurrence: occurrence,
                onEdit: { showEditor() },
                onClose: { popover = nil })
        case .editor:
            EventEditorView(mode: .edit(occurrence), onClose: { popover = nil })
        }
    }

    private func handleClick() {
        isFocused = true
        if CalendarClick.isDoubleClick() {
            showEditor()
        } else {
            showDetails()
        }
    }

    private func showDetails() {
        model.selectedOccurrenceID = occurrence.id
        popover = .details
    }

    /// A folder written by a newer version can't be changed, so there the details stand in for the editor.
    private func showEditor() {
        model.selectedOccurrenceID = occurrence.id
        popover = model.isReadOnly ? .details : .editor
    }

    /// Focused on the next turn of the run loop, once the view that just appeared is in the window.
    private func takeFocusIfClaimed() {
        guard let claimsFocus, claimsFocus() else { return }
        Task { @MainActor in
            isFocused = true
        }
    }

    /// The details a `-demo` screenshot scene asked for, presented once the block is in the window.
    private func openPendingDetails() {
        let id = occurrence.id
        guard handlesPendingEditor, model.pendingDetailsOccurrenceID == id else { return }
        Task { @MainActor in
            guard model.pendingDetailsOccurrenceID == id else { return }
            model.pendingDetailsOccurrenceID = nil
            popover = .details
        }
    }

    private func openPendingEditor() {
        let id = occurrence.id
        guard handlesPendingEditor, model.pendingEditorOccurrenceID == id else { return }
        model.selectedOccurrenceID = id
        let kind: EventPopoverKind = model.isReadOnly ? .details : .editor
        // Presented on the next turn of the run loop, once a block that just appeared is in the window and
        // the time grid has scrolled to it (it looks for the pending ID, so that is cleared only now).
        Task { @MainActor in
            guard model.pendingEditorOccurrenceID == id else { return }
            model.pendingEditorOccurrenceID = nil
            popover = kind
        }
    }
}

/// The rounded shape behind an event: an opaque `BackgroundWindow` underlay (so hour lines don't show
/// through and the title keeps the contrast `SubjectStyle` worked out), the subject fill and its 1 pt
/// border, and on the selected event the amber ring with its soft glow.
struct EventShapeBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    let subject: Subject?
    let isSelected: Bool
    var cornerRadius: CGFloat = Metrics.Radius.eventBlock

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let border = CalendarEventStyle.border(for: subject, scheme: colorScheme, contrast: contrast)
        let glow = isSelected ? Color.accentColor.opacity(0.45) : Color.clear
        let glowRadius = isSelected ? Metrics.Glow.selectionShadowRadius : 0
        ZStack {
            shape.fill(Color.backgroundWindow)
            shape.fill(SubjectStyle.fill(for: subject, scheme: colorScheme))
            shape.strokeBorder(border, lineWidth: 1)
            if isSelected {
                shape.strokeBorder(Color.accentColor, lineWidth: Metrics.Glow.selectionRing)
            }
        }
        .compositingGroup()
        .shadow(color: glow, radius: glowRadius)
    }
}
