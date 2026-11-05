import Foundation

/// Persistent "always allow" rules, in the same format as Claude Code's --allowedTools:
/// "Bash(git:*)", "Edit", "WebFetch". Passed to the CLI when the process starts, and matched locally
/// for a process that is already running.
@MainActor
final class PermissionRules: ObservableObject {
    static let shared = PermissionRules()
    nonisolated static let readOnly = ["Read", "Grep", "Glob", "WebSearch", "WebFetch", "TodoWrite"]

    @Published private(set) var rules: [String]

    init() { rules = UserDefaults.standard.stringArray(forKey: "permissionRules") ?? [] }

    func add(_ r: String) {
        guard !rules.contains(r) else { return }
        rules.append(r)
        UserDefaults.standard.set(rules, forKey: "permissionRules")
    }

    func remove(_ r: String) {
        rules.removeAll { $0 == r }
        UserDefaults.standard.set(rules, forKey: "permissionRules")
    }

    /// Shell commands that chain several commands must not be covered by a prefix rule.
    nonisolated static func isCompound(_ cmd: String) -> Bool {
        ["&&", "||", ";", "|", "`", "$(", ">", "<", "\n"].contains { cmd.contains($0) }
    }

    /// Suggested rule for one request. nil = no safe suggestion.
    nonisolated static func suggestion(tool: String, input: [String: Any]) -> (rule: String, label: String)? {
        switch tool {
        case "Bash":
            guard let cmd = (input["command"] as? String)?.trimmingCharacters(in: .whitespaces),
                  !isCompound(cmd) else { return nil }
            let words = cmd.split(separator: " ").map(String.init)
            guard let first = words.first, !first.contains("/"), !["sudo", "rm", "dd", "mkfs"].contains(first) else { return nil }
            // commands with subcommands (git status, npm run, docker ps) → 2 words; others 1 word
            let multi: Set<String> = ["git", "npm", "pnpm", "yarn", "docker", "kubectl", "gh", "brew", "cargo", "go", "swift", "pm2", "systemctl", "adb"]
            let prefix = (multi.contains(first) && words.count > 1 && !words[1].hasPrefix("-")) ? "\(first) \(words[1])" : first
            return ("Bash(\(prefix):*)", "\(prefix) …")
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            return ("Edit", tr("edit files", "edit file"))
        default:
            return (tool, tool)
        }
    }

    /// Match a request against the saved rules.
    func allows(tool: String, input: [String: Any]) -> Bool {
        for r in rules {
            if r == tool { return true }
            if r == "Edit", ["Edit", "MultiEdit", "Write", "NotebookEdit"].contains(tool) { return true }
            if tool == "Bash", r.hasPrefix("Bash("), r.hasSuffix(":*)"),
               let cmd = (input["command"] as? String)?.trimmingCharacters(in: .whitespaces), !Self.isCompound(cmd) {
                let prefix = String(r.dropFirst(5).dropLast(3))
                if cmd == prefix || cmd.hasPrefix(prefix + " ") { return true }
            }
        }
        return false
    }
}

/// Permission mode: ask every time / always allow (answered automatically by the app) / skip all checks (bypassPermissions).
enum PermMode: String, CaseIterable {
    case ask, always, bypass

    var label: String {
        switch self {
        case .ask: return tr("Ask first", "Tanya dulu")
        case .always: return tr("Always allow", "Selalu izinkan")
        case .bypass: return tr("Skip all permissions", "Lewati semua izin")
        }
    }
    var symbol: String {
        switch self {
        case .ask: return "hand.raised"
        case .always: return "checkmark.shield"
        case .bypass: return "exclamationmark.shield.fill"
        }
    }
    var detail: String {
        switch self {
        case .ask: return tr("A permission card appears for every tool that changes something", "Kartu izin muncul untuk tiap tool yang mengubah sesuatu")
        case .always: return tr("Every permission request is approved automatically", "Semua permintaan izin langsung disetujui otomatis")
        case .bypass: return tr("--dangerously-skip-permissions: Claude never asks at all", "--dangerously-skip-permissions: Claude tidak pernah minta izin sama sekali")
        }
    }

    static var current: PermMode {
        let d = UserDefaults.standard
        if let s = d.string(forKey: "permMode"), let m = PermMode(rawValue: s) { return m }
        return d.bool(forKey: "bypassPermissions") ? .bypass : .ask   // migrate the old setting
    }
    static func save(_ m: PermMode) {
        UserDefaults.standard.set(m.rawValue, forKey: "permMode")
        UserDefaults.standard.removeObject(forKey: "bypassPermissions")
    }
}

/// How long an automatic permission mode (Always allow / Bypass) lasts before falling back to Ask first.
enum PermScope: String, CaseIterable {
    case chat, hour, always

    var label: String {
        switch self {
        case .chat: return tr("For this chat", "Untuk chat ini")
        case .hour: return tr("For 1 hour", "Selama 1 jam")
        case .always: return tr("Until I change it", "Sampai saya ubah")
        }
    }

    static var current: PermScope {
        PermScope(rawValue: UserDefaults.standard.string(forKey: "permModeScope") ?? "") ?? .always
    }
    static var until: Date? { UserDefaults.standard.object(forKey: "permModeUntil") as? Date }

    static func save(_ s: PermScope, until: Date?) {
        let d = UserDefaults.standard
        d.set(s.rawValue, forKey: "permModeScope")
        if let until { d.set(until, forKey: "permModeUntil") } else { d.removeObject(forKey: "permModeUntil") }
    }
}
