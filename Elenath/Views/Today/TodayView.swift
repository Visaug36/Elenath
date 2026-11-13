import ElenathCore
import SwiftUI

/// The landing screen: what waits in the Inbox, open tasks, and what was edited lately.
///
/// Today reads the spaces that mix. A sealed space is not in it: it has its own page.
struct TodayView: View {
    @Environment(AppModel.self) private var model
    @State private var inbox: [NoteHit] = []
    @State private var tasks: [TaskHit] = []
    @State private var recent: [NoteHit] = []
    @State private var showsAllTasks = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                VStack(alignment: .leading, spacing: 14) {
                    inboxCard
                    tasksCard
                    recentCard
                }
                .frame(maxWidth: Metrics.editorColumnWidth, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.top, 18)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
        }
        .task(id: model.contentRevision) {
            await load()
        }
    }

    /// "Today" and the date, on a band with stars.
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Today")
                .font(Typography.windowTitle)
                .foregroundStyle(Color.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: model.timeSource.now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .font(Typography.body)
                .foregroundStyle(Color.textSecondary)
        }
        .frame(maxWidth: Metrics.editorColumnWidth, alignment: .leading)
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity)
        .frame(height: 96)
        .starryBackground(.backgroundWindow)
    }

    private var inboxCard: some View {
        SectionCard(title: Text("Inbox")) {
            if model.inboxCount > 0 {
                Button("Open Inbox") {
                    model.go(to: .inbox)
                }
                .buttonStyle(.plain)
                .font(Typography.footnote)
                .foregroundStyle(Color.accentText)
                .padding(.trailing, 10)
            }
        } content: {
            if model.inboxCount == 0 {
                CardPlaceholder(text: Text("Nothing waiting."))
            } else {
                Text("\(model.inboxCount) waiting to be filed")
                    .font(Typography.secondary)
                    .monospacedDigit()
                    .foregroundStyle(Color.textSecondary)
                    .padding(.horizontal, 10)
                ForEach(inbox.prefix(3), id: \.note) { hit in
                    OpenableRow(dragURL: model.url(for: hit.note.path, in: hit.note.container)) {
                        model.open(hit.note)
                    } content: {
                        NoteRowView(hit: hit)
                    }
                    .contextMenu {
                        NoteMenu(note: hit.note)
                    }
                }
            }
        }
    }

    private var tasksCard: some View {
        SectionCard(title: Text("Open tasks")) {
            if tasks.count > 8 {
                Button(showsAllTasks ? "Show Fewer" : "Show All") {
                    showsAllTasks.toggle()
                }
                .buttonStyle(.plain)
                .font(Typography.footnote)
                .foregroundStyle(Color.accentText)
                .padding(.trailing, 10)
            }
        } content: {
            if tasks.isEmpty {
                CardPlaceholder(text: Text("No open tasks."))
            } else {
                ForEach(Array(tasks.prefix(showsAllTasks ? 200 : 8).enumerated()), id: \.offset) { _, task in
                    TaskRowView(task: task)
                }
            }
        }
    }

    private var recentCard: some View {
        SectionCard(title: Text("Recently edited")) {
            if recent.isEmpty {
                CardPlaceholder(text: Text("Notes you edit show up here."))
            } else {
                ForEach(recent, id: \.note) { hit in
                    OpenableRow(dragURL: model.url(for: hit.note.path, in: hit.note.container)) {
                        model.open(hit.note)
                    } content: {
                        NoteRowView(hit: hit, showsPlace: true)
                    }
                    .contextMenu {
                        NoteMenu(note: hit.note)
                    }
                }
            }
        }
    }

    private func load() async {
        guard let services = model.services else { return }
        inbox = (try? await services.retrieval.recentNotes(from: .inbox, limit: 3)) ?? []
        tasks = (try? await services.retrieval.openTasks(from: .everywhere, limit: 200)) ?? []
        recent = (try? await services.retrieval.recentNotes(from: .everywhere, limit: 6)) ?? []
    }
}
