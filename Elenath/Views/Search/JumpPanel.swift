import ElenathCore
import SwiftUI

/// ⌘O: a panel in the middle of the window to jump to a note by its title. It lists recent notes until
/// something is typed. ↑ and ↓ move, ↩ opens, esc closes.
struct JumpPanel: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var hits: [NoteHit] = []
    @State private var selected = 0
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture {
                    close()
                }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.textSecondary)
                        .accessibilityHidden(true)
                    TextField("Jump to a note…", text: $text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 17))
                        .focused($isFocused)
                        .onSubmit {
                            openSelected()
                        }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                if !hits.isEmpty {
                    Rectangle()
                        .fill(Color.separatorLine)
                        .frame(height: 1)
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 1) {
                                ForEach(Array(hits.enumerated()), id: \.element.note) { index, hit in
                                    Button {
                                        open(hit)
                                    } label: {
                                        NoteRowView(hit: hit, showsPlace: true)
                                            .background {
                                                if index == selected {
                                                    RoundedRectangle(
                                                        cornerRadius: Metrics.Radius.listRow, style: .continuous
                                                    )
                                                    .fill(Color.accentSoft)
                                                }
                                            }
                                    }
                                    .buttonStyle(.plain)
                                    .id(index)
                                }
                            }
                            .padding(6)
                        }
                        .frame(maxHeight: 340)
                        .onChange(of: selected) { _, index in
                            proxy.scrollTo(index)
                        }
                    }
                }
            }
            .frame(width: 520)
            .raisedPanelBackground(cornerRadius: Metrics.Radius.panel)
            .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
            .padding(.top, 90)
        }
        .onKeyPress(.downArrow) {
            selected = min(selected + 1, max(hits.count - 1, 0))
            return .handled
        }
        .onKeyPress(.upArrow) {
            selected = max(selected - 1, 0)
            return .handled
        }
        .onKeyPress(.escape) {
            close()
            return .handled
        }
        .onAppear {
            isFocused = true
        }
        .task(id: text) {
            guard let services = model.services else { return }
            let found = (try? await services.retrieval.titles(matching: text, from: model.workplace, limit: 12)) ?? []
            guard !Task.isCancelled else { return }
            hits = found
            selected = 0
        }
        .accessibilityAddTraits(.isModal)
    }

    private func openSelected() {
        guard hits.indices.contains(selected) else { return }
        open(hits[selected])
    }

    private func open(_ hit: NoteHit) {
        close()
        model.open(hit.note)
    }

    private func close() {
        model.isJumpPanelShown = false
    }
}
