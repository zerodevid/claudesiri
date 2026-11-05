import Foundation

/// Session history: index of ClaudeSiri sessions in UserDefaults + reader for claude's .jsonl transcripts.
struct SessionInfo: Identifiable, Equatable, Codable {
    let id: String
    var title: String
    var date: Date
    var workDir: String
    var mine = true
}

@MainActor
final class History: ObservableObject {
    static let shared = History()
    @Published private(set) var mine: [SessionInfo] = []
    @Published private(set) var all: [SessionInfo] = []
    @Published private(set) var loadingAll = false

    init() {
        if let d = UserDefaults.standard.data(forKey: "sessions"),
           let s = try? JSONDecoder().decode([SessionInfo].self, from: d) { mine = s }
    }

    func record(id: String, title: String, workDir: String) {
        if let i = mine.firstIndex(where: { $0.id == id }) {
            mine[i].date = Date()
            let s = mine.remove(at: i); mine.insert(s, at: 0)
        } else {
            let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
            mine.insert(SessionInfo(id: id, title: t.isEmpty ? tr("(image)", "(gambar)") : String(t.prefix(80)), date: Date(), workDir: workDir), at: 0)
        }
        if mine.count > 300 { mine.removeLast(mine.count - 300) }
        save()
    }

    func forget(_ id: String) {
        mine.removeAll { $0.id == id }
        all.removeAll { $0.id == id }
        save()
    }

    private func save() {
        if let d = try? JSONEncoder().encode(mine) { UserDefaults.standard.set(d, forKey: "sessions") }
    }

    nonisolated static func projectDir(for workDir: String) -> String {
        let enc = workDir.map { ($0 == "/" || $0 == ".") ? "-" : String($0) }.joined()
        return ClaudeRunner.configDir + "/projects/" + enc
    }

    /// All sessions in the working folder (including terminal ones), newest 60.
    func loadAll(workDir: String) {
        guard !loadingAll else { return }
        loadingAll = true
        let mineIDs = Set(mine.map(\.id))
        let dir = Self.projectDir(for: workDir)
        Task.detached {
            let fm = FileManager.default
            let files = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".jsonl") }
            let dated: [(String, Date)] = files.compactMap { f in
                let p = dir + "/" + f
                guard let a = try? fm.attributesOfItem(atPath: p), let d = a[.modificationDate] as? Date else { return nil }
                return (p, d)
            }.sorted { $0.1 > $1.1 }
            var out: [SessionInfo] = []
            for (p, d) in dated.prefix(60) {
                let id = ((p as NSString).lastPathComponent as NSString).deletingPathExtension
                let title = Self.peekTitle(path: p) ?? tr("(untitled)", "(tanpa judul)")
                out.append(SessionInfo(id: id, title: title, date: d, workDir: workDir, mine: mineIDs.contains(id)))
            }
            let found = out
            await MainActor.run { self.all = found; self.loadingAll = false }
        }
    }

    /// Title: ai-title if it is in the first 256 KB, otherwise the first user message.
    nonisolated static func peekTitle(path: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let data = (try? h.read(upToCount: 256 * 1024)) ?? Data()
        var firstUser: String?
        for line in data.split(separator: 0x0A) {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if o["type"] as? String == "ai-title", let t = o["aiTitle"] as? String { return t }
            if firstUser == nil, let t = userText(o) { firstUser = String(t.prefix(80)) }
        }
        if firstUser != nil { return firstUser }
        // long sessions: ai-title is often near the end of the file
        if let end = try? h.seekToEnd(), end > 256 * 1024 {
            try? h.seek(toOffset: end - 256 * 1024)
            let tail = (try? h.readToEnd()) ?? Data()
            for line in tail.split(separator: 0x0A).reversed() {
                guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                if o["type"] as? String == "ai-title", let t = o["aiTitle"] as? String { return t }
                if o["type"] as? String == "last-prompt", let t = o["lastPrompt"] as? String, !t.isEmpty { return String(t.prefix(80)) }
            }
        }
        return nil
    }

    /// Human message text from one jsonl line, without the injected context block.
    nonisolated static func userText(_ o: [String: Any]) -> String? {
        rawUserText(o).map { splitContext($0).text }
    }

    /// Split the <context> block that ClaudeSiri puts in front of a message into the app name,
    /// the selected text, and the message the user actually typed.
    nonisolated static func splitContext(_ t: String) -> (app: String?, selected: String?, text: String) {
        for (open, close) in [("<context>", "</context>"), ("<konteks>", "</konteks>")] {   // <konteks> = older versions
            guard let o = t.range(of: open), let c = t.range(of: close, range: o.upperBound..<t.endIndex) else { continue }
            let inner = String(t[o.upperBound..<c.lowerBound])
            let rest = String(t[c.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            var app: String?
            if let header = inner.split(separator: "\n", maxSplits: 1).first,
               let m = header.firstMatch(of: #/(?: in | di )(.+):\s*$/#) { app = String(m.1) }
            var selected: String?
            if let q1 = inner.range(of: "\"\"\"\n"), let q2 = inner.range(of: "\n\"\"\"", options: .backwards), q1.upperBound <= q2.lowerBound {
                selected = String(inner[q1.upperBound..<q2.lowerBound])
            }
            return (app, selected, rest)
        }
        return (nil, nil, t)
    }

    /// Full human message text from one jsonl line (skips meta/tool_result/sidechain).
    nonisolated static func rawUserText(_ o: [String: Any]) -> String? {
        guard o["type"] as? String == "user", o["isMeta"] as? Bool != true, o["isSidechain"] as? Bool != true,
              let msg = o["message"] as? [String: Any] else { return nil }
        var text: String?
        if let s = msg["content"] as? String { text = s }
        else if let blocks = msg["content"] as? [[String: Any]] {
            if blocks.contains(where: { $0["type"] as? String == "tool_result" }) { return nil }
            let parts = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            let imgs = blocks.filter { $0["type"] as? String == "image" }.count
            text = (imgs > 0 ? "🖼 \(imgs) · " : "") + parts.joined(separator: "\n")
        }
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty,
              !t.hasPrefix("<local-command"), !t.hasPrefix("<command-"), !t.hasPrefix("Caveat:") else { return nil }
        if t.hasPrefix("<system-reminder>") { return nil }
        return t
    }

    /// Rebuild the conversation from a transcript.
    nonisolated static func loadMessages(id: String, workDir: String)
        -> [(user: Bool, text: String, contextApp: String?, contextText: String?)] {
        let path = projectDir(for: workDir) + "/\(id).jsonl"
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        var out: [(user: Bool, text: String, contextApp: String?, contextText: String?)] = []
        for line in data.split(separator: 0x0A) {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if let raw = rawUserText(o) {
                let c = splitContext(raw)
                out.append((true, c.text, c.app, c.selected))
            } else if o["type"] as? String == "assistant", o["isSidechain"] as? Bool != true,
                      let msg = o["message"] as? [String: Any],
                      let blocks = msg["content"] as? [[String: Any]] {
                let t = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                    .joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { continue }
                if let last = out.last, !last.user { out[out.count - 1].text += "\n\n" + t }
                else { out.append((false, t, nil, nil)) }
            }
        }
        return out
    }
}
