import ElenathCore
import SwiftUI

/// One timed event in the Day or Week grid: the subject fill and border (radius 6), the title in the
/// subject's readable color on up to two lines, and the time range with `paperclip` and the file count when
/// the block is tall enough. Past events are dimmed and the selected one gets the amber ring and glow.
/// Click, double-click, Return and VoiceOver come from `eventInteraction`.
///
/// Files dropped on the block are copied into the event's folder: while they are over it, the block gets
/// the drop ring and glow, and while they copy, a thin amber progress bar runs along its bottom.
///
/// Dragging the block moves the event and dragging its bottom edge changes its end (`eventBlockDrag`,
/// `EventBlockResizeHandle`); with the block focused, ⌥↑ / ⌥↓ and ⌥⇧↑ / ⌥⇧↓ do the same from the keyboard.
struct EventBlockView: View {
    @Environment(CalendarModel.self) private var model
    @Environment(FilesController.self) private var files
    @Environment(\.colorSchemeContrast) private var contrast
    let item: DayLayout.Item
    let arrowEdge: Edge
    /// Whether this block opens Quick Add's editor for its occurrence: only one segment of an event drawn
    /// across several days does, the first one on screen.
    let handlesPendingEditor: Bool
    /// The grid's drag state and where this block's day column is.
    let dragContext: TimeGridDragContext
    @State private var drag = FileDragState()

    var body: some View {
        let occurrence = item.occurrence
        let subject = model.subject(for: occurrence.event)
        let isSelected = model.selectedOccurrenceID == occurrence.id
        let density = EventBlockDensity(height: TimeGridGeometry.height(of: item) - TimeGridGeometry.blockGap)
        let fileCount = files.fileCount(for: occurrence)
        let state = dragContext.state
        EventBlockLabel(occurrence: occurrence, subject: subject, density: density, fileCount: fileCount ?? 0)
            .background {
                EventShapeBackground(subject: subject, isSelected: isSelected)
            }
            .overlay(alignment: .bottom) {
                EventBlockImportBar(occurrenceID: occurrence.id)
            }
            .overlay(alignment: .bottom) {
                if model.canEdit, !item.continuesAfter {
                    EventBlockResizeHandle(item: item, context: dragContext)
                }
            }
            .opacity(CalendarEventStyle.opacity(for: occurrence, now: model.now, contrast: contrast))
            .modifier(EventBlockDropHighlight(isTargeted: drag.isTargeted))
            .contentShape(RoundedRectangle(cornerRadius: Metrics.Radius.eventBlock, style: .continuous))
            .fileDropTarget(isEnabled: model.canEdit, state: $drag) { urls in
                files.addFiles(urls, to: occurrence)
            }
            .eventBlockDrag(item: item, context: dragContext)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spokenLabel(for: occurrence, fileCount: fileCount))
            .accessibilityAddTraits(CalendarEventStyle.traits(isSelected: isSelected))
            .eventInteraction(
                occurrence: occurrence, arrowEdge: arrowEdge, handlesPendingEditor: handlesPendingEditor,
                claimsFocus: { state.claimsFocus(occurrence.id) }
            )
            .eventBlockKeyboardMoves(occurrence: occurrence, context: dragContext)
            .onAppear {
                files.requestCounts(for: [occurrence])
            }
            .onChange(of: occurrence) {
                files.requestCounts(for: [occurrence])
            }
    }

    /// "Physics Lecture, 2:00 PM to 3:30 PM, 4 files": the file count once it is known and not zero.
    private func spokenLabel(for occurrence: Occurrence, fileCount: Int?) -> String {
        let label = EventFormatting.accessibilityLabel(occurrence, timeZone: model.timeZone)
        guard let fileCount, fileCount > 0 else { return label }
        return EventFormatting.spokenJoined([label, FileLabels.count(fileCount)])
    }
}

/// How much an event block has room for.
private enum EventBlockDensity {
    /// The title on one line (blocks shorter than about 45 minutes).
    case compact
    /// The title on one line, then the time range.
    case regular
    /// The title on up to two lines, then the time range (about 75 minutes and longer).
    case roomy

    init(height: CGFloat) {
        if height < 34 {
            self = .compact
        } else if height < 50 {
            self = .regular
        } else {
            self = .roomy
        }
    }
}

/// The text of a block: the title, then the time range followed by `paperclip` and the file count when the
/// event has files.
private struct EventBlockLabel: View {
    @Environment(CalendarModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    let occurrence: Occurrence
    let subject: Subject?
    let density: EventBlockDensity
    let fileCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(EventFormatting.displayTitle(occurrence.event))
                .font(Typography.eventTitle)
                .foregroundStyle(SubjectStyle.text(for: subject, scheme: colorScheme))
                .lineLimit(density == .roomy ? 2 : 1)
                .truncationMode(.tail)
            if density != .compact {
                HStack(spacing: 5) {
                    Text(EventFormatting.timeRange(occurrence, timeZone: model.timeZone))
                        .lineLimit(1)
                    if fileCount > 0 {
                        EventBlockFileCount(count: fileCount)
                    }
                }
                .font(Typography.eventTime)
                .monospacedDigit()
                .foregroundStyle(Color.textSecondary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, density == .compact ? 1 : 3)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }
}

/// `paperclip` and how many files the event has (11 pt, tabular digits). It keeps its width when the
/// time range has to shorten.
private struct EventBlockFileCount: View {
    let count: Int

    var body: some View {
        HStack(spacing: 1) {
            Image(systemName: "paperclip")
            Text(count, format: .number)
        }
        .lineLimit(1)
        .fixedSize()
        .layoutPriority(1)
        .accessibilityHidden(true)
    }
}

/// While files are dragged over a block: the 1.5 pt amber ring and a soft amber glow behind it (DESIGN.md:
/// 32 pt at 32 %).
private struct EventBlockDropHighlight: ViewModifier {
    let isTargeted: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.Radius.eventBlock, style: .continuous)
        let glow = Color.accentColor.opacity(Metrics.Glow.dropShadowOpacity)
        content
            .background {
                if isTargeted {
                    shape
                        .fill(Color.backgroundWindow)
                        .shadow(color: glow, radius: Metrics.Glow.dropShadowRadius)
                        .accessibilityHidden(true)
                }
            }
            .overlay {
                if isTargeted {
                    shape
                        .strokeBorder(Color.accentColor, lineWidth: Metrics.Glow.dropRing)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}

/// A 2 pt amber bar along the bottom of a block while files are copied into the event's folder. It reads
/// the copy's progress itself, so progress updates redraw only the bar.
private struct EventBlockImportBar: View {
    @Environment(FilesController.self) private var files
    let occurrenceID: Occurrence.ID

    var body: some View {
        if let progress = files.imports[occurrenceID] {
            Capsule()
                .fill(Color.accentColor)
                .frame(height: 2)
                .scaleEffect(x: CGFloat(min(1, max(0.05, progress.fractionCompleted))), anchor: .leading)
                .padding(.horizontal, 4)
                .padding(.bottom, 2)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
