import AppKit
import ElenathCore
import SwiftUI

/// The sheet for a new space and for editing one: name, color, symbol, sealed, description and keywords
/// (docs/DESIGN.md, "Spaces").
struct SpaceSheet: View {
    let request: SpaceSheetRequest
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft = Space(name: "")
    @State private var keywords = ""
    @State private var customColor = Color(.sRGB, red: 0.55, green: 0.6, blue: 0.75)
    @State private var hasLoaded = false

    /// Symbols to choose from. `sparkles` is Nano bot's own, so it isn't offered.
    static let symbols = [
        "folder", "graduationcap", "cross.case", "lightbulb", "person", "house", "book", "briefcase", "heart",
        "star", "leaf", "paintbrush", "music.note", "camera", "airplane", "cart", "dumbbell", "brain", "atom",
        "globe", "flag", "hammer", "gamecontroller", "pawprint",
    ]

    private var isNew: Bool {
        request == .new
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isNew ? "New Space" : "Edit Space")
                .font(Typography.detailTitle)
                .foregroundStyle(Color.textPrimary)
                .padding(.horizontal, Metrics.Padding.popover)
                .padding(.top, Metrics.Padding.popover)
            Form {
                TextField("Name", text: $draft.name)
                LabeledContent("Color") {
                    colorSwatches
                }
                LabeledContent("Symbol") {
                    symbolGrid
                }
                Section {
                    Toggle("Sealed", isOn: $draft.isSealed)
                        .toggleStyle(.switch)
                        .tint(Color.accentColor)
                } footer: {
                    Text(
                        "Keep this space apart. Its notes stay out of search, links and suggestions everywhere else, and nothing from other spaces shows up inside it."
                    )
                    .font(Typography.footnote)
                    .foregroundStyle(Color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Section {
                    TextField("Description", text: $draft.description, axis: .vertical)
                        .lineLimit(1...3)
                    TextField("Keywords", text: $keywords, prompt: Text("uni, lecture, exam"))
                } footer: {
                    Text(
                        "These help file things here. Typing a keyword and a colon in Quick Capture files straight into this space."
                    )
                    .font(Typography.footnote)
                    .foregroundStyle(Color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(isNew ? "Create Space" : "Done") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Color.accentColor)
                .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty || !model.canEdit)
            }
            .padding(Metrics.Padding.popover)
        }
        .frame(width: 440)
        .background(Color.backgroundWindow)
        .onAppear {
            load()
        }
    }

    private var colorSwatches: some View {
        HStack(spacing: 10) {
            ForEach(PaletteColor.allCases, id: \.self) { palette in
                swatch(Color(SpaceStyle.resource(for: palette)), isSelected: draft.color == .palette(palette)) {
                    draft.color = .palette(palette)
                }
                .accessibilityLabel(Text(verbatim: palette.rawValue.capitalized))
            }
            ColorPicker(selection: $customColor, supportsOpacity: false) {
                EmptyView()
            }
            .labelsHidden()
            .onChange(of: customColor) { _, color in
                if let custom = Self.spaceColor(from: color) {
                    draft.color = custom
                }
            }
            .accessibilityLabel(Text("Custom color"))
        }
    }

    private func swatch(_ color: Color, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 20, height: 20)
                .overlay {
                    if isSelected {
                        Circle()
                            .strokeBorder(Color.accentColor, lineWidth: Metrics.Glow.selectionRing)
                            .padding(-4)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var symbolGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 6), count: 8), spacing: 6) {
            ForEach(Self.symbols, id: \.self) { symbol in
                Button {
                    draft.symbol = symbol
                } label: {
                    Image(systemName: symbol)
                        .font(.system(size: 13))
                        .foregroundStyle(draft.symbol == symbol ? Color.accentText : Color.textSecondary)
                        .frame(width: 26, height: 26)
                        .background {
                            if draft.symbol == symbol {
                                RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous)
                                    .fill(Color.accentSoft)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: symbol))
                .accessibilityAddTraits(draft.symbol == symbol ? .isSelected : [])
            }
        }
    }

    private func load() {
        guard !hasLoaded else { return }
        hasLoaded = true
        if case .edit(let id) = request, let space = model.space(id) {
            draft = space
            keywords = space.keywords.joined(separator: ", ")
            if case .custom(let red, let green, let blue) = space.color {
                customColor = Color(.sRGB, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
            }
        } else {
            draft = Space(name: "", color: .palette(.teal), symbol: "folder")
        }
    }

    private func save() {
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.keywords = Space.normalizedKeywords(keywords.split(separator: ",").map(String.init))
        if isNew {
            model.createSpace(draft)
        } else {
            model.updateSpace(draft)
        }
        dismiss()
    }

    /// A color from the color well, as a custom space color.
    private static func spaceColor(from color: Color) -> SpaceColor? {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        func byte(_ value: CGFloat) -> UInt8 {
            UInt8(max(0, min(255, (value * 255).rounded())))
        }
        return .custom(red: byte(rgb.redComponent), green: byte(rgb.greenComponent), blue: byte(rgb.blueComponent))
    }
}
