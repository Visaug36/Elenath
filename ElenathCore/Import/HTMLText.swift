import Foundation

/// The text of a web page or a Safari web archive as Markdown (docs/IMPORT.md): headings, paragraphs,
/// list items and line breaks, and nothing else.
///
/// It reads the markup itself instead of handing it to WebKit, so an imported page never runs a script,
/// never asks for anything over the network, and is read off the main thread in time that grows with its
/// length. Scripts, styles and the page's head are left out.
public enum HTMLText {
    /// Markdown from HTML bytes: UTF-8 unless the bytes say otherwise (a byte order mark, or a charset
    /// near the start).
    public static func markdown(fromHTML data: Data) -> String {
        markdown(fromHTML: decode(data, encodingName: nil))
    }

    /// Markdown from a Safari web archive: its main page's text. Nil when the file isn't one.
    public static func markdown(fromWebArchive data: Data) -> String? {
        guard
            let archive = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let main = archive["WebMainResource"] as? [String: Any],
            let page = main["WebResourceData"] as? Data
        else { return nil }
        return markdown(fromHTML: decode(page, encodingName: main["WebResourceTextEncodingName"] as? String))
    }

    /// Markdown from HTML text.
    public static func markdown(fromHTML html: String) -> String {
        var reader = Reader(units: Array(html.unicodeScalars))
        reader.run()
        return reader.finished()
    }

    // MARK: - Private

    private static func decode(_ data: Data, encodingName: String?) -> String {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16) ?? ""
        }
        var name = encodingName?.lowercased()
        if name == nil {
            let head = String(decoding: data.prefix(1_024), as: UTF8.self).lowercased()
            if let range = head.range(of: "charset=") {
                name = String(
                    head[range.upperBound...].drop { $0 == "\"" || $0 == "'" }.prefix {
                        $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_"
                    })
            }
        }
        if let name, ["windows-1252", "iso-8859-1", "latin1", "cp1252"].contains(name) {
            return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Tags that end a paragraph, and what starts the next one.
    private static let blockTags: Set<String> = [
        "p", "div", "section", "article", "header", "footer", "main", "nav", "aside", "blockquote", "pre",
        "ul", "ol", "li", "table", "tr", "td", "th", "h1", "h2", "h3", "h4", "h5", "h6", "hr", "dl", "dt", "dd",
        "figure", "figcaption", "form", "address", "body", "html",
    ]
    /// Tags whose contents are left out entirely.
    private static let skippedTags: Set<String> = ["script", "style", "head", "noscript", "template", "svg", "title"]

    private static let entities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "ndash": "–", "mdash": "—",
        "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "copy": "©", "reg": "®",
        "trade": "™", "euro": "€", "pound": "£", "middot": "·", "bull": "•", "times": "×", "deg": "°",
    ]

    private struct Reader {
        let units: [Unicode.Scalar]
        var index = 0
        var lines: [String] = []
        var line = String.UnicodeScalarView()
        var prefix = ""
        /// Inside <pre>: spaces and line breaks are kept, in a fenced code block.
        var preformatted = 0
        var pendingSpace = false
        var lastLineIsListItem = false

        init(units: [Unicode.Scalar]) {
            self.units = units
        }

        mutating func run() {
            while index < units.count {
                let unit = units[index]
                if unit == "<" {
                    readTag()
                } else if unit == "&" {
                    readEntity()
                } else {
                    text(unit)
                    index += 1
                }
            }
        }

        mutating func finished() -> String {
            if preformatted > 0 {
                if !line.isEmpty {
                    lines.append(String(line))
                }
                line = String.UnicodeScalarView()
                lines.append("```")
            }
            endLine()
            var result: [String] = []
            for line in lines {
                if line.isEmpty, result.last?.isEmpty ?? true {
                    continue
                }
                result.append(line)
            }
            while result.last?.isEmpty == true {
                result.removeLast()
            }
            return result.isEmpty ? "" : result.joined(separator: "\n") + "\n"
        }

        private mutating func text(_ unit: Unicode.Scalar) {
            if preformatted > 0 {
                if unit == "\n" {
                    lines.append(String(line))
                    line = String.UnicodeScalarView()
                } else if unit != "\r" {
                    line.append(unit)
                }
                return
            }
            if unit.properties.isWhitespace {
                pendingSpace = !line.isEmpty
                return
            }
            if pendingSpace {
                line.append(" ")
                pendingSpace = false
            }
            line.append(unit)
        }

        /// Ends the line being read, if it has text.
        private mutating func endLine() {
            let text = String(line).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                lines.append(prefix + text)
                lastLineIsListItem = prefix == "- "
            }
            line = String.UnicodeScalarView()
            prefix = ""
            pendingSpace = false
        }

        /// A blank line before what comes next, as Markdown separates paragraphs.
        private mutating func breakParagraph() {
            if let last = lines.last, !last.isEmpty {
                lines.append("")
            }
            lastLineIsListItem = false
        }

        /// `<…>`: a tag, a comment or a declaration. A "<" that starts none of them is text.
        private mutating func readTag() {
            let start = index
            if starts(with: "<!--") {
                index = find("-->", from: index + 4).map { $0 + 3 } ?? units.count
                return
            }
            var cursor = index + 1
            let closing = cursor < units.count && units[cursor] == "/"
            if closing {
                cursor += 1
            }
            var name = ""
            while cursor < units.count, units[cursor].properties.isAlphabetic || ("0"..."9").contains(units[cursor]) {
                name.unicodeScalars.append(units[cursor])
                cursor += 1
            }
            guard !name.isEmpty || (cursor < units.count && units[cursor] == "!") else {
                text(units[start])
                index = start + 1
                return
            }
            // The end of the tag, past any quoted attribute values.
            var quote: Unicode.Scalar?
            while cursor < units.count {
                let unit = units[cursor]
                if let open = quote {
                    if unit == open {
                        quote = nil
                    }
                } else if unit == "\"" || unit == "'" {
                    quote = unit
                } else if unit == ">" {
                    break
                }
                cursor += 1
            }
            index = min(cursor + 1, units.count)
            handle(name.lowercased(), closing: closing)
        }

        private mutating func handle(_ name: String, closing: Bool) {
            if !closing && HTMLText.skippedTags.contains(name) {
                // Everything up to the matching closing tag is left out.
                let end = "</" + name
                index =
                    find(end, from: index, caseInsensitive: true).map { position in
                        find(">", from: position).map { $0 + 1 } ?? units.count
                    } ?? units.count
                return
            }
            if preformatted > 0 && name != "pre" {
                if name == "br" {
                    text("\n")
                }
                return
            }
            if name == "br" {
                endLine()
                return
            }
            if name == "pre" {
                if closing {
                    guard preformatted > 0 else { return }
                    if !line.isEmpty {
                        lines.append(String(line))
                        line = String.UnicodeScalarView()
                    }
                    lines.append("```")
                    preformatted = 0
                    breakParagraph()
                } else {
                    endLine()
                    breakParagraph()
                    lines.append("```")
                    preformatted = 1
                    // A line break right after <pre> isn't part of the text.
                    if index < units.count, units[index] == "\n" {
                        index += 1
                    }
                }
                return
            }
            guard HTMLText.blockTags.contains(name) else { return }
            endLine()
            if name == "li" {
                // List items stay together; the list is a block of its own.
                if !closing && !lastLineIsListItem {
                    breakParagraph()
                }
            } else {
                breakParagraph()
            }
            guard !closing else { return }
            switch name {
            case "h1", "h2", "h3", "h4", "h5", "h6":
                prefix = String(repeating: "#", count: Int(String(name.dropFirst())) ?? 1) + " "
            case "li":
                prefix = "- "
            case "blockquote":
                prefix = "> "
            default:
                break
            }
        }

        /// `&name;`, `&#123;` or `&#x7B;`. An ampersand that starts none of them is text.
        private mutating func readEntity() {
            var cursor = index + 1
            var name = ""
            while cursor < units.count, cursor - index <= 10, units[cursor] != ";" {
                name.unicodeScalars.append(units[cursor])
                cursor += 1
            }
            guard cursor < units.count, units[cursor] == ";", let value = HTMLText.entity(name) else {
                text("&")
                index += 1
                return
            }
            for unit in value.unicodeScalars {
                text(unit)
            }
            index = cursor + 1
        }

        private func starts(with text: String) -> Bool {
            let wanted = Array(text.unicodeScalars)
            guard index + wanted.count <= units.count else { return false }
            return units[index..<(index + wanted.count)].elementsEqual(wanted)
        }

        /// Where `text` next starts, from `start` on.
        private func find(_ text: String, from start: Int, caseInsensitive: Bool = false) -> Int? {
            let wanted = Array((caseInsensitive ? text.lowercased() : text).unicodeScalars)
            guard !wanted.isEmpty, start <= units.count - wanted.count else { return nil }
            var position = start
            while position <= units.count - wanted.count {
                var matches = true
                for offset in 0..<wanted.count {
                    var unit = units[position + offset]
                    if caseInsensitive, ("A"..."Z").contains(unit) {
                        unit = Unicode.Scalar(unit.value + 32)!
                    }
                    if unit != wanted[offset] {
                        matches = false
                        break
                    }
                }
                if matches {
                    return position
                }
                position += 1
            }
            return nil
        }
    }

    private static func entity(_ name: String) -> String? {
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let value: UInt32?
            if digits.first == "x" || digits.first == "X" {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits)
            }
            guard let value, value != 0, let scalar = Unicode.Scalar(value) else { return nil }
            return String(scalar)
        }
        return entities[name]
    }
}
