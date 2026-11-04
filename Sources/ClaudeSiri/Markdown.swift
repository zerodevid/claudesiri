import SwiftUI
import AppKit

/// Markdown rendering: headings, paragraphs (inline + clickable links), lists, quotes, rules,
/// code blocks (with a copy button) and tables.
struct MarkdownText: View {
    let text: String
    var size: CGFloat = 15

    enum Block: Hashable {
        case heading(Int, String)
        case prose(String)
        case quote(String)
        case code(String, String)          // language, body
        case table([String], [[String]])   // header, rows
        case rule
    }

    static func parse(_ text: String) -> [Block] {
        var out: [Block] = []
        var prose: [String] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        func flush() {
            let s = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !s.isEmpty { out.append(.prose(s)) }
            prose = []
        }
        func cells(_ l: String) -> [String] {
            var t = l.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("|") { t.removeFirst() }
            if t.hasSuffix("|") { t.removeLast() }
            return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        func isSeparator(_ l: String) -> Bool {
            let t = l.trimmingCharacters(in: .whitespaces)
            return t.contains("-") && t.allSatisfy { "|-: ".contains($0) }
        }
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flush()
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i]); i += 1
                }
                out.append(.code(lang, code.joined(separator: "\n")))
                i += 1
                continue
            }
            if trimmed.hasPrefix("|"), i + 1 < lines.count, isSeparator(lines[i + 1]) {
                flush()
                let header = cells(trimmed)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    var r = cells(lines[i])
                    if r.count < header.count { r += Array(repeating: "", count: header.count - r.count) }
                    rows.append(Array(r.prefix(header.count)))
                    i += 1
                }
                out.append(.table(header, rows))
                continue
            }
            if let r = trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flush()
                let level = trimmed[r].filter { $0 == "#" }.count
                out.append(.heading(level, String(trimmed[r.upperBound...])))
                i += 1; continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flush(); out.append(.rule); i += 1; continue
            }
            if trimmed.hasPrefix(">") {
                flush()
                var q: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    q.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                out.append(.quote(q.joined(separator: "\n")))
                continue
            }
            prose.append(line)
            i += 1
        }
        flush()
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.parse(text).enumerated()), id: \.offset) { _, b in
                block(b)
            }
        }
        .tint(Color(red: 0.45, green: 0.68, blue: 1))
        .textSelection(.enabled)
    }

    @ViewBuilder private func block(_ b: Block) -> some View {
        switch b {
        case .heading(let lvl, let s):
            Text(Self.attributed(s))
                .font(.system(size: size + CGFloat(max(0, 4 - lvl)) * 2, weight: .semibold))
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .prose(let s):
            Text(Self.attributed(Self.bullets(s)))
                .font(.system(size: size))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .quote(let s):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.25)).frame(width: 3)
                Text(Self.attributed(s)).font(.system(size: size)).foregroundStyle(Color(white: 0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .rule:
            Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
        case .code(let lang, let s):
            CodeBlock(lang: lang, code: s, size: size)
        case .table(let h, let rows):
            TableBlock(header: h, rows: rows, size: size)
        }
    }

    static func bullets(_ s: String) -> String {
        s.components(separatedBy: "\n").map { line -> String in
            if let r = line.range(of: #"^(\s*)[-*+]\s+"#, options: .regularExpression) {
                let indent = line[r].prefix { $0 == " " }
                return indent + "•  " + line[r.upperBound...]
            }
            return line
        }.joined(separator: "\n")
    }

    /// Inline markdown + bare URLs turned into links (outside `code`).
    static func attributed(_ s: String) -> AttributedString {
        let parts = s.components(separatedBy: "`")
        let linked = parts.enumerated().map { i, p -> String in
            guard i % 2 == 0 else { return p }
            return p.replacingOccurrences(of: #"(?<![\(\[<])(https?://[^\s<>\)\]]+[^\s<>\)\].,;:!?'"])"#,
                                          with: "[$1]($1)", options: .regularExpression)
        }.joined(separator: "`")
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: linked, options: opts)) ?? AttributedString(s)
    }
}

struct CodeBlock: View {
    let lang: String
    let code: String
    let size: CGFloat
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(lang.isEmpty ? "kode" : lang).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.dim)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Label(copied ? "Tersalin" : "Salin", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11)).foregroundStyle(copied ? .green : Theme.dim)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: size - 2, design: .monospaced))
                    .foregroundStyle(Color(white: 0.86))
                    .padding(.horizontal, 12).padding(.bottom, 12).padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
    }
}

struct TableBlock: View {
    let header: [String]
    let rows: [[String]]
    let size: CGFloat

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, h in
                        Text(MarkdownText.attributed(h)).font(.system(size: size - 1, weight: .semibold))
                            .padding(.vertical, 8)
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(Array(r.enumerated()), id: \.offset) { _, c in
                            Text(MarkdownText.attributed(c)).font(.system(size: size - 1))
                                .foregroundStyle(Color(white: 0.88))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: 320, alignment: .leading)
                                .padding(.vertical, 7)
                        }
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 4)
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.08)))
    }
}
