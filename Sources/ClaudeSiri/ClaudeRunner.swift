import Foundation

/// Stats for one answer turn (from the `result` event).
struct TurnStats: Equatable {
    var model: String?
    var durationMs: Int = 0
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var costUSD: Double = 0
}

/// One `claude` process per chat session, two-way over stream-json:
/// - user messages (text + images) are written to stdin
/// - tool permissions arrive as control_request (can_use_tool) and are answered on stdin
/// - Stop = interrupt control_request (process stays alive), model switch = set_model
final class ClaudeRunner {
    enum Event {
        case sessionID(String)
        case newTurn
        case textDelta(String)
        case tool(name: String, detail: String)
        case permission(id: String, tool: String, input: [String: Any], description: String?)
        case finished(isError: Bool, stopped: Bool, result: String?, stats: TurnStats?)
    }

    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var sawText = false
    private var turnOpen = false
    private var stderrText = ""
    private var onEvent: ((Event) -> Void)?
    private let writeQueue = DispatchQueue(label: "claudesiri.stdin")
    private var killTimer: DispatchWorkItem?

    /// Model for the next / running process ("" = CLI default).
    var model: String = UserDefaults.standard.string(forKey: "model") ?? ""

    var isRunning: Bool { process?.isRunning ?? false }

    static func claudePath() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            UserDefaults.standard.string(forKey: "claudePath") ?? "",
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.claude/local/claude",
        ]
        return candidates.first { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The claude config folder in use (for reading session history).
    static var configDir: String {
        if let d = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !d.isEmpty { return d }
        let pulse = NSHomeDirectory() + "/.claude-pulse/active"
        if FileManager.default.fileExists(atPath: pulse) { return pulse }
        return NSHomeDirectory() + "/.claude"
    }

    /// content = Anthropic message blocks: [{"type":"text",...}, {"type":"image",...}]
    func send(content: [[String: Any]], sessionID: String?, workDir: String, allowed: [String], onEvent: @escaping (Event) -> Void) {
        self.onEvent = onEvent
        if !isRunning {
            guard start(sessionID: sessionID, workDir: workDir, allowed: allowed) else { return }
        }
        sawText = false
        turnOpen = true
        write(["type": "user", "message": ["role": "user", "content": content]])
    }

    func respond(id: String, allow: Bool, input: [String: Any], message: String? = nil) {
        let inner: [String: Any] = allow
            ? ["behavior": "allow", "updatedInput": input]
            : ["behavior": "deny", "message": message ?? "User menolak izin ini."]
        write(["type": "control_response",
               "response": ["subtype": "success", "request_id": id, "response": inner]])
    }

    /// Stop the running answer without killing the process. No response within 4 s → kill it.
    func interrupt() {
        guard isRunning, turnOpen else { return }
        control(["subtype": "interrupt"])
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.turnOpen else { return }
            self.kill()
        }
        killTimer = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: w)
    }

    /// Bypass mode: applied when the process starts, and sent live if it is already running.
    var bypass = false
    func setBypass(_ on: Bool) {
        guard on != bypass else { return }
        bypass = on
        if isRunning { control(["subtype": "set_permission_mode", "mode": on ? "bypassPermissions" : "default"]) }
    }

    func setModel(_ m: String) {
        model = m
        if isRunning { control(["subtype": "set_model", "model": m.isEmpty ? "default" : m]) }
    }

    /// Kill the process (new chat / folder change). The next message starts a new one with --resume.
    func kill() {
        guard let p = process else { return }
        process = nil
        stdin = nil
        p.terminate()
        if turnOpen {
            turnOpen = false
            let cb = onEvent
            DispatchQueue.main.async { cb?(.finished(isError: false, stopped: true, result: nil, stats: nil)) }
        }
    }

    // MARK: -

    private func emit(_ ev: Event) {
        if case .finished = ev {
            guard turnOpen else { return }
            turnOpen = false
            killTimer?.cancel()
        }
        onEvent?(ev)
    }

    private func control(_ req: [String: Any]) {
        write(["type": "control_request", "request_id": UUID().uuidString, "request": req])
    }

    private func write(_ obj: [String: Any]) {
        guard let h = stdin, var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        data.append(0x0A)
        writeQueue.async { try? h.write(contentsOf: data) }
    }

    private func start(sessionID: String?, workDir: String, allowed: [String]) -> Bool {
        guard let path = Self.claudePath() else {
            onEvent?(.finished(isError: true, stopped: false,
                               result: "CLI `claude` tidak ketemu. Set path: defaults write id.zerodev.claudesiri claudePath /path/ke/claude",
                               stats: nil))
            return false
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        var args = ["-p",
                    "--input-format", "stream-json",
                    "--output-format", "stream-json",
                    "--verbose", "--include-partial-messages",
                    "--permission-prompt-tool", "stdio"]
        if let sid = sessionID { args += ["--resume", sid] }
        // allows switching to bypass mid-session via set_permission_mode
        args += ["--allow-dangerously-skip-permissions"]
        if bypass { args += ["--permission-mode", "bypassPermissions"] }
        // read-only tools + "always allow" rules run directly; everything else asks through the UI
        args += ["--allowedTools"] + PermissionRules.readOnly + allowed
        if !model.isEmpty { args += ["--model", model] }
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: workDir)

        // Env: drop API keys inherited from .zshrc so the claude.ai login is used (and the active Claude Pulse account, if any).
        var env = ProcessInfo.processInfo.environment
        for k in ["ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT"] {
            env.removeValue(forKey: k)
        }
        let home = NSHomeDirectory()
        if env["CLAUDE_CONFIG_DIR"] == nil,
           FileManager.default.fileExists(atPath: "\(home)/.claude-pulse/active") {
            env["CLAUDE_CONFIG_DIR"] = "\(home)/.claude-pulse/active"
        }
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        p.environment = env

        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = inp
        buffer = Data()
        stderrText = ""

        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard let self, !chunk.isEmpty else { return }
            self.buffer.append(chunk)
            while let nl = self.buffer.firstIndex(of: 0x0A) {
                let line = self.buffer.subdata(in: self.buffer.startIndex..<nl)
                self.buffer.removeSubrange(self.buffer.startIndex...nl)
                DispatchQueue.main.async { self.handle(line: line) }
            }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            if let s = String(data: h.availableData, encoding: .utf8) {
                DispatchQueue.main.async { self?.stderrText += s }
            }
        }
        p.terminationHandler = { [weak self] proc in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self else { return }
                if self.process === proc { self.process = nil; self.stdin = nil }
                let msg = self.stderrText.split(separator: "\n")
                    .filter { !$0.contains("connectors are disabled") }.joined(separator: "\n")
                if proc.terminationReason == .uncaughtSignal {
                    self.emit(.finished(isError: false, stopped: true, result: nil, stats: nil))
                } else {
                    self.emit(.finished(isError: true, stopped: false,
                                        result: msg.isEmpty ? "claude berhenti (kode \(proc.terminationStatus))" : msg,
                                        stats: nil))
                }
            }
        }
        do {
            try p.run()
            process = p
            stdin = inp.fileHandleForWriting
            return true
        } catch {
            onEvent?(.finished(isError: true, stopped: false, result: "Gagal menjalankan claude: \(error.localizedDescription)", stats: nil))
            return false
        }
    }

    private func handle(line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "system":
            if obj["subtype"] as? String == "init", let sid = obj["session_id"] as? String {
                emit(.sessionID(sid))
            }
        case "control_request":
            guard let id = obj["request_id"] as? String,
                  let req = obj["request"] as? [String: Any] else { return }
            if req["subtype"] as? String == "can_use_tool" {
                emit(.permission(id: id,
                                 tool: req["tool_name"] as? String ?? "tool",
                                 input: req["input"] as? [String: Any] ?? [:],
                                 description: req["description"] as? String))
            } else {
                write(["type": "control_response",
                       "response": ["subtype": "error", "request_id": id, "error": "tidak didukung"]])
            }
        case "stream_event":
            guard let ev = obj["event"] as? [String: Any], let et = ev["type"] as? String else { return }
            if et == "message_start", sawText {
                emit(.newTurn)
            } else if et == "content_block_delta",
                      let delta = ev["delta"] as? [String: Any],
                      delta["type"] as? String == "text_delta",
                      let t = delta["text"] as? String {
                sawText = true
                emit(.textDelta(t))
            }
        case "assistant":
            guard let msg = obj["message"] as? [String: Any],
                  let content = msg["content"] as? [[String: Any]] else { return }
            for block in content where block["type"] as? String == "tool_use" {
                let name = block["name"] as? String ?? "tool"
                let input = block["input"] as? [String: Any] ?? [:]
                emit(.tool(name: name, detail: Self.summary(of: input)))
            }
        case "result":
            let subtype = obj["subtype"] as? String ?? ""
            let stopped = subtype == "error_during_execution"
            var st = TurnStats()
            st.durationMs = obj["duration_ms"] as? Int ?? 0
            st.costUSD = obj["total_cost_usd"] as? Double ?? 0
            if let u = obj["usage"] as? [String: Any] {
                st.inputTokens = (u["input_tokens"] as? Int ?? 0) + (u["cache_read_input_tokens"] as? Int ?? 0)
                    + (u["cache_creation_input_tokens"] as? Int ?? 0)
                st.outputTokens = u["output_tokens"] as? Int ?? 0
            }
            if let mu = obj["modelUsage"] as? [String: Any] { st.model = mu.keys.sorted().first }
            emit(.finished(isError: !stopped && (obj["is_error"] as? Bool ?? false), stopped: stopped,
                           result: obj["result"] as? String, stats: stopped ? nil : st))
        default:
            break
        }
    }

    static func summary(of input: [String: Any]) -> String {
        (input["command"] ?? input["file_path"] ?? input["pattern"] ?? input["query"]
         ?? input["url"] ?? input["description"]) as? String ?? ""
    }
}
