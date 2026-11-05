import Foundation
import AppKit
import Combine
import UniformTypeIdentifiers

struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
    var tools: [String] = []
    var isError = false
    var calc: CalcResult?
    var images: [NSImage] = []
    var context: String?          // "Selected text from Safari"
    var stats: TurnStats?
}

/// An image attached before sending.
struct Attachment: Identifiable, Equatable {
    let id = UUID()
    let image: NSImage
    let mediaType: String
    let base64: String

    /// Downscale to a long side of ≤1568 px (the model's effective limit) as PNG; fall back to JPEG above 3.5 MB.
    static func make(from img: NSImage) -> Attachment? {
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let maxSide: CGFloat = 1568
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = min(1, maxSide / max(w, h))
        let nw = Int(w * scale), nh = Int(h * scale)
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        guard let scaled = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: scaled)
        var type = "image/png"
        guard var data = rep.representation(using: .png, properties: [:]) else { return nil }
        if data.count > 3_500_000, let j = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
            data = j; type = "image/jpeg"
        }
        return Attachment(image: NSImage(cgImage: scaled, size: NSSize(width: nw, height: nh)),
                          mediaType: type, base64: data.base64EncodedString())
    }
}

/// A permission request from Claude waiting for the user's answer.
struct PermissionRequest: Identifiable, Equatable {
    let id: String
    let tool: String
    let title: String      // one-line summary
    let detail: String     // body (command / path + content excerpt)
    let input: [String: Any]
    let ruleSuggestion: String?
    let ruleLabel: String?
    static func == (a: Self, b: Self) -> Bool { a.id == b.id }

    init(id: String, tool: String, input: [String: Any], description: String?) {
        self.id = id; self.tool = tool; self.input = input
        let sug = PermissionRules.suggestion(tool: tool, input: input)
        ruleSuggestion = sug?.rule; ruleLabel = sug?.label
        func str(_ k: String) -> String? { input[k] as? String }
        switch tool {
        case "Bash":
            title = description ?? str("description") ?? "Jalankan perintah"
            detail = str("command") ?? ""
        case "Edit", "MultiEdit":
            title = "Ubah file"
            let path = str("file_path") ?? ""
            let old = str("old_string").map { "− " + $0.prefix(300) } ?? ""
            let new = str("new_string").map { "+ " + $0.prefix(300) } ?? ""
            detail = [path, old, new].filter { !$0.isEmpty }.joined(separator: "\n")
        case "Write":
            title = "Tulis file"
            detail = (str("file_path") ?? "") + "\n" + String((str("content") ?? "").prefix(400))
        default:
            title = description ?? tool
            if let d = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys]),
               let t = String(data: d, encoding: .utf8) { detail = String(t.prefix(600)) } else { detail = "" }
        }
    }
}

@MainActor
final class ChatModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var input = "" { didSet { if input != oldValue { schedulePreview() } } }
    private var previewWork: DispatchWorkItem?

    /// Compute the preview once typing has paused for 0.5 s (so it does not jump around mid-typing).
    private func schedulePreview() {
        previewWork?.cancel()
        if input.trimmingCharacters(in: .whitespaces).isEmpty { preview = nil; return }
        let w = DispatchWorkItem { [weak self] in self?.updatePreview() }
        previewWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }
    @Published var preview: CalcResult?
    @Published var busy = false
    @Published var expanded = false
    @Published var currentTool: String?
    @Published var focusTick = 0
    @Published var attachments: [Attachment] = []
    @Published var permissions: [PermissionRequest] = []
    @Published var selected: ScreenContext.Selected?
    @Published var contextAppName: String?
    @Published var showHistory = false
    @Published var modelChoice: String = UserDefaults.standard.string(forKey: "model") ?? ""
    @Published var micText: String?
    @Published private(set) var permMode = PermMode.current
    let speech = SpeechInput()
    var contextApp: NSRunningApplication?
    /// Called when Claude needs attention (a permission) → AppDelegate shows the panel.
    var onAttention: (() -> Void)?
    /// Called when an answer finishes: (text, duration in seconds).
    var onFinished: ((String, Double) -> Void)?
    private var turnStart = Date()
    private var speechSink: Any?

    private(set) var sessionID: String?
    private let runner = ClaudeRunner()
    private var ratesSink: Any?

    init() {
        let r = Rates.shared
        ratesSink = r.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.updatePreview() }
        }
        r.refreshIfStale()
        runner.model = modelChoice
        runner.setBypass(permMode == .bypass)
        speechSink = speech.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.objectWillChange.send() }
        }
    }

    static let models: [(id: String, label: String)] = [("", "Default"), ("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku")]

    /// Switch the permission mode; for anything but "ask", queued requests are approved right away.
    func setPermMode(_ m: PermMode) {
        permMode = m
        PermMode.save(m)
        runner.setBypass(m == .bypass)
        if m != .ask {
            for r in permissions { runner.respond(id: r.id, allow: true, input: r.input) }
            if let last = permissions.last { currentTool = "\(last.tool) · \(last.detail.prefix(80))" }
            permissions = []
        }
    }

    func setModel(_ m: String) {
        modelChoice = m
        UserDefaults.standard.set(m, forKey: "model")
        runner.setModel(m)
    }

    /// Called whenever the panel appears: remember the frontmost app and the text selected in it.
    func captureContext() {
        guard let app = ScreenContext.frontApp() else { return }
        contextApp = app
        contextAppName = app.localizedName
        if UserDefaults.standard.object(forKey: "grabSelection") as? Bool ?? true,
           let t = ScreenContext.selectedText(in: app), t != selected?.text {
            selected = ScreenContext.Selected(app: app.localizedName ?? "app", text: t)
        }
    }

    /// Attach a screenshot of the previously active app's window.
    func attachWindowShot() {
        guard let app = contextApp else { return }
        if let img = ScreenContext.captureWindow(of: app) { addImages([img]) }
        else if !CGPreflightScreenCaptureAccess() {
            messages.append(ChatMessage(role: .assistant, text: "Butuh izin **Screen Recording** untuk ClaudeSiri (System Settings › Privacy & Security › Screen & System Audio Recording). Setelah diizinkan, buka ulang app-nya.", isError: true))
        }
    }

    func toggleMic() {
        speech.toggle(onText: { [weak self] t in self?.input = t },
                      onDone: { [weak self] t in self?.input = t; self?.submit() })
    }

    func updatePreview() {
        let p = Calculator.evaluate(input)
        if p != preview { preview = p }
    }

    /// Enter: math/conversion → answer locally; anything else → Claude.
    func submit() {
        previewWork?.cancel()
        updatePreview()   // Enter before the debounce fires still uses the latest result
        if let p = preview, !busy {
            let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
            messages.append(ChatMessage(role: .user, text: text))
            messages.append(ChatMessage(role: .assistant, text: p.value, calc: p))
            input = ""
            return
        }
        send()
    }
    var workDir: String = UserDefaults.standard.string(forKey: "workDir") ?? NSHomeDirectory()

    var lastAssistant: ChatMessage? { messages.last(where: { $0.role == .assistant }) }
    var lastUser: ChatMessage? { messages.last(where: { $0.role == .user }) }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || !attachments.isEmpty), !busy else { return }
        input = ""
        let atts = attachments
        attachments = []
        let sel = selected
        selected = nil
        let firstOfChat = messages.allSatisfy { $0.calc != nil }
        messages.append(ChatMessage(role: .user, text: text, images: atts.map(\.image),
                                    context: sel.map { "Teks terpilih dari \($0.app)" }))
        messages.append(ChatMessage(role: .assistant, text: ""))
        busy = true
        currentTool = nil
        let idx = messages.count - 1

        var content: [[String: Any]] = atts.map {
            ["type": "image", "source": ["type": "base64", "media_type": $0.mediaType, "data": $0.base64]]
        }
        var prompt = text.isEmpty ? "Lihat gambar ini." : text
        if let sel {
            prompt = "<konteks>Teks yang sedang saya pilih di \(sel.app):\n\"\"\"\n\(sel.text)\n\"\"\"</konteks>\n\n" + prompt
        }
        content.append(["type": "text", "text": prompt])
        turnStart = Date()
        let title = text.isEmpty ? "(gambar)" : text

        runner.send(content: content, sessionID: sessionID, workDir: workDir,
                    allowed: PermissionRules.shared.rules) { [weak self] ev in
            guard let self, idx < self.messages.count else { return }
            switch ev {
            case .sessionID(let sid):
                self.sessionID = sid
                History.shared.record(id: sid, title: firstOfChat ? title : (History.shared.mine.first { $0.id == sid }?.title ?? title),
                                      workDir: self.workDir)
            case .newTurn:
                if !self.messages[idx].text.hasSuffix("\n\n") { self.messages[idx].text += "\n\n" }
            case .textDelta(let t):
                self.currentTool = nil
                self.messages[idx].text += t
            case .tool(let name, let detail):
                let line = detail.isEmpty ? name : "\(name) · \(detail.prefix(80))"
                self.messages[idx].tools.append(line)
                self.currentTool = line
            case .permission(let id, let tool, let input, let desc):
                if self.permMode != .ask || PermissionRules.shared.allows(tool: tool, input: input) {
                    self.runner.respond(id: id, allow: true, input: input)
                } else {
                    self.permissions.append(PermissionRequest(id: id, tool: tool, input: input, description: desc))
                    NSSound(named: "Tink")?.play()
                    self.onAttention?()
                }
            case .finished(let isErr, let stopped, let result, let stats):
                self.busy = false
                self.currentTool = nil
                self.permissions = []
                self.messages[idx].stats = stats
                if isErr {
                    self.messages[idx].isError = true
                    if let r = result, !r.isEmpty { self.messages[idx].text = r }
                } else if self.messages[idx].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.messages[idx].text = stopped ? "(dihentikan)" : (result ?? "(selesai, tanpa teks)")
                } else if stopped {
                    self.messages[idx].text += "\n\n_(dihentikan)_"
                }
                self.messages[idx].text = self.messages[idx].text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let sid = self.sessionID { History.shared.record(id: sid, title: title, workDir: self.workDir) }
                self.onFinished?(self.messages[idx].text, Date().timeIntervalSince(self.turnStart))
            }
        }
    }

    /// Answer a permission request. always = save a permanent rule (e.g. "Bash(git status:*)").
    func answerPermission(_ req: PermissionRequest, allow: Bool, always: Bool = false) {
        if always, let rule = req.ruleSuggestion { PermissionRules.shared.add(rule) }
        runner.respond(id: req.id, allow: allow, input: req.input)
        permissions.removeAll { $0.id == req.id }
        if always {
            for r in permissions where PermissionRules.shared.allows(tool: r.tool, input: r.input) {
                runner.respond(id: r.id, allow: true, input: r.input)
            }
            permissions.removeAll { PermissionRules.shared.allows(tool: $0.tool, input: $0.input) }
        }
        if allow { currentTool = "\(req.tool) · \(req.detail.prefix(80))" }
    }

    /// Open an old session from history.
    func loadSession(_ info: SessionInfo) {
        runner.kill()
        let msgs = History.loadMessages(id: info.id, workDir: info.workDir)
        messages = msgs.map { ChatMessage(role: $0.user ? .user : .assistant, text: $0.text) }
        sessionID = info.id
        workDir = info.workDir
        busy = false
        permissions = []
        currentTool = nil
        input = ""
        showHistory = false
        focusTick += 1
    }

    func addImages(_ imgs: [NSImage]) {
        for i in imgs { if let a = Attachment.make(from: i) { attachments.append(a) } }
        focusTick += 1
    }

    func pickImages() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        p.allowsMultipleSelection = true
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK {
            addImages(p.urls.compactMap { NSImage(contentsOf: $0) })
        }
        onAttention?()   // the panel may have hidden while the file dialog was open
    }

    /// ⌘V: if the clipboard holds an image (and no text) → attach it. Returns true when handled.
    func pasteImageIfAny() -> Bool {
        let pb = NSPasteboard.general
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true,
                                                          .urlReadingContentsConformToTypes: ["public.image"]]
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: opts) as? [URL], !urls.isEmpty {
            addImages(urls.compactMap { NSImage(contentsOf: $0) }); return true
        }
        if pb.string(forType: .string) != nil { return false }
        if let imgs = pb.readObjects(forClasses: [NSImage.self]) as? [NSImage], !imgs.isEmpty {
            addImages(imgs); return true
        }
        return false
    }

    func stop() { runner.interrupt() }

    func newChat() {
        runner.kill()
        permissions = []
        attachments = []
        selected = nil
        messages = []
        sessionID = nil
        busy = false
        currentTool = nil
        input = ""
        focusTick += 1
    }

    func copyLast() {
        guard let a = lastAssistant else { return }
        let t = a.calc?.copyText ?? a.text
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t, forType: .string)
    }

    /// Continue the same session in Terminal.app (claude --resume).
    func openInTerminal() {
        let dir = workDir.replacingOccurrences(of: "'", with: "'\\''")
        var cmd = "cd '\(dir)' && unset ANTHROPIC_API_KEY ANTHROPIC_BASE_URL && "
        if let cfg = ClaudeRunner.customConfigDir {
            cmd += "export CLAUDE_CONFIG_DIR='\(cfg.replacingOccurrences(of: "'", with: "'\\''"))' && "
        }
        cmd += "claude"
        if let sid = sessionID { cmd += " --resume \(sid)" }
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"\nend tell"
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
    }
}
