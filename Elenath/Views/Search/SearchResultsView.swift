import ElenathCore
import SwiftUI

/// The results for what is typed in the toolbar's search field, with filters for where, what kind, which
/// tag and when.
///
/// A search reads what the place it was started from may read: from inside a sealed space that is the
/// space alone, and from anywhere else no sealed space is in it.
struct SearchResultsView: View {
    @Environment(AppModel.self) private var model
    @State private var hits: [SearchHit] = []
    @State private var hasSearched = false
    @State private var scope: Scope = .everywhere
    @State private var kind: NoteKind?
    @State private var tag: String?
    @State private var period: Period = .anyTime
    @State private var selection: SearchHit.Item?

    enum Scope: Hashable {
        /// Everything the place the search started in may read.
        case everywhere
        /// Only the space the search started in.
        case thisSpace
    }

    enum Period: Hashable, CaseIterable {
        case anyTime, pastWeek, pastMonth, pastYear

        var name: Text {
            switch self {
            case .anyTime: Text("Any Time")
            case .pastWeek: Text("Past Week")
            case .pastMonth: Text("Past Month")
            case .pastYear: Text("Past Year")
            }
        }

        func start(from now: Date) -> Date? {
            switch self {
            case .anyTime: nil
            case .pastWeek: now.addingTimeInterval(-7 * 86_400)
            case .pastMonth: now.addingTimeInterval(-31 * 86_400)
            case .pastYear: now.addingTimeInterval(-366 * 86_400)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            filters
            if hits.isEmpty && hasSearched {
                emptyState
            } else {
                List(selection: $selection) {
                    ForEach(hits, id: \.item) { hit in
                        SearchResultRow(hit: hit)
                            .tag(hit.item)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .contextMenu(forSelectionType: SearchHit.Item.self) { _ in
                    EmptyView()
                } primaryAction: { items in
                    if let item = items.first {
                        open(item)
                    }
                }
                .onKeyPress(.return) {
                    guard let selection else { return .ignored }
                    open(selection)
                    return .handled
                }
            }
        }
        .background(Color.backgroundWindow)
        .task(
            id: Query(
                text: model.searchText, scope: scope, kind: kind, tag: tag, period: period,
                revision: model.contentRevision)
        ) {
            await search()
        }
    }

    private struct Query: Hashable {
        var text: String
        var scope: Scope
        var kind: NoteKind?
        var tag: String?
        var period: Period
        var revision: Int
    }

    /// The space the search was started in, if it was started in one.
    private var originSpace: Space? {
        if case .space(let id) = model.searchOrigin {
            return model.space(id)
        }
        return nil
    }

    private var filters: some View {
        HStack(spacing: 8) {
            if let space = originSpace {
                if space.isSealed {
                    Label("\(space.name) only", systemImage: "lock.fill")
                        .font(Typography.footnote)
                        .foregroundStyle(Color.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.controlFill, in: Capsule())
                } else {
                    FilterMenu(
                        title: scope == .thisSpace ? Text(verbatim: space.name) : Text("Everywhere"),
                        isActive: scope == .thisSpace
                    ) {
                        Button("Everywhere") { scope = .everywhere }
                        Button(space.name) { scope = .thisSpace }
                    }
                }
            } else if model.searchOrigin == .inbox {
                Label("Inbox only", systemImage: "tray")
                    .font(Typography.footnote)
                    .foregroundStyle(Color.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.controlFill, in: Capsule())
            }
            FilterMenu(
                title: kind.map { Text(verbatim: KindStyle.name(for: $0)) } ?? Text("Any Kind"), isActive: kind != nil
            ) {
                Button("Any Kind") { kind = nil }
                ForEach(NoteKind.allCases, id: \.self) { choice in
                    Button(KindStyle.name(for: choice)) { kind = choice }
                }
            }
            FilterMenu(title: tag.map { Text(verbatim: "#\($0)") } ?? Text("Any Tag"), isActive: tag != nil) {
                Button("Any Tag") { tag = nil }
                ForEach(model.tags, id: \.tag) { choice in
                    Button {
                        tag = choice.tag
                    } label: {
                        Text(verbatim: "#\(choice.tag)")
                    }
                }
            }
            FilterMenu(title: period.name, isActive: period != .anyTime) {
                ForEach(Period.allCases, id: \.self) { choice in
                    Button {
                        period = choice
                    } label: {
                        choice.name
                    }
                }
            }
            Spacer()
            if hasSearched {
                Text("\(hits.count) results")
                    .font(Typography.footnote)
                    .monospacedDigit()
                    .foregroundStyle(Color.textTertiary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(.emptySearch)
                .accessibilityHidden(true)
                .padding(.bottom, 10)
            Text("Nothing by that name.")
                .font(Typography.emptyHeadline)
                .foregroundStyle(Color.textPrimary)
            Text("No notes match “\(model.searchText)”.")
                .font(Typography.secondary)
                .foregroundStyle(Color.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func search() async {
        guard let services = model.services else { return }
        let text = model.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            hits = []
            hasSearched = false
            return
        }
        // A short pause, so that typing a word is one search and not one per letter.
        do {
            try await Task.sleep(for: .milliseconds(80))
        } catch {
            return
        }
        var query = SearchQuery(text: text, tag: tag, kind: kind, limit: 60)
        query.modifiedAfter = period.start(from: model.timeSource.now)
        if scope == .thisSpace, let space = originSpace {
            query.space = space.id
        }
        let found = (try? await services.retrieval.search(query, from: model.searchOrigin)) ?? []
        guard !Task.isCancelled else { return }
        hits = found
        hasSearched = true
        if let selection, !found.contains(where: { $0.item == selection }) {
            self.selection = nil
        }
    }

    private func open(_ item: SearchHit.Item) {
        switch item {
        case .note(let note):
            let terms = hits.first { $0.item == item }?.matchedTerms ?? []
            model.open(note, highlighting: terms)
        case .file(let container, let path):
            model.openFile(path, in: container)
        }
    }
}

/// A capsule that opens a menu of choices; amber-tinted while a choice narrows the search.
private struct FilterMenu<Choices: View>: View {
    let title: Text
    let isActive: Bool
    @ViewBuilder var choices: Choices

    var body: some View {
        Menu {
            choices
        } label: {
            title
                .font(Typography.footnote)
                .foregroundStyle(isActive ? Color.accentText : Color.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(isActive ? Color.accentSoft : Color.controlFill, in: Capsule())
    }
}

/// One result: the title, a snippet with the matched words marked, and where and when.
private struct SearchResultRow: View {
    let hit: SearchHit
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(Color.textSecondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: hit.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                if !hit.snippet.text.isEmpty {
                    Text(marked(hit.snippet))
                        .font(Typography.secondary)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(2)
                }
                PlaceLabel(container: place.container, folder: place.folder)
            }
            Spacer(minLength: 8)
            Text(verbatim: DateText.short(hit.modified, now: model.timeSource.now))
                .font(Typography.footnote)
                .monospacedDigit()
                .foregroundStyle(Color.textTertiary)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch hit.item {
        case .note: "doc.text"
        case .file: "doc"
        }
    }

    private var place: (container: Container, folder: ItemPath) {
        switch hit.item {
        case .note(let note): (note.container, note.path.folder)
        case .file(let container, let path): (container, path.folder)
        }
    }

    /// The snippet with what matched in the primary text color on an amber wash.
    private func marked(_ snippet: MarkedText) -> AttributedString {
        var result = AttributedString(snippet.text)
        for mark in snippet.marks {
            guard let range = Range(mark, in: snippet.text),
                let lower = AttributedString.Index(range.lowerBound, within: result),
                let upper = AttributedString.Index(range.upperBound, within: result)
            else { continue }
            result[lower..<upper].backgroundColor = Color.accentSoft
            result[lower..<upper].foregroundColor = Color.textPrimary
        }
        return result
    }
}
