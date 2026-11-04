import Foundation

/// Aturan "selalu izinkan" yang disimpan permanen, format sama dengan --allowedTools Claude Code:
/// "Bash(git:*)", "Edit", "WebFetch". Dikirim ke CLI saat proses mulai, dan dicocokkan lokal
/// untuk proses yang sudah jalan.
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

    /// Perintah shell yang menyambung beberapa perintah tidak boleh ikut aturan prefiks.
    nonisolated static func isCompound(_ cmd: String) -> Bool {
        ["&&", "||", ";", "|", "`", "$(", ">", "<", "\n"].contains { cmd.contains($0) }
    }

    /// Usulan aturan untuk satu permintaan. nil = tak ada usulan aman.
    nonisolated static func suggestion(tool: String, input: [String: Any]) -> (rule: String, label: String)? {
        switch tool {
        case "Bash":
            guard let cmd = (input["command"] as? String)?.trimmingCharacters(in: .whitespaces),
                  !isCompound(cmd) else { return nil }
            let words = cmd.split(separator: " ").map(String.init)
            guard let first = words.first, !first.contains("/"), !["sudo", "rm", "dd", "mkfs"].contains(first) else { return nil }
            // perintah bertingkat (git status, npm run, docker ps) → 2 kata; lainnya 1 kata
            let multi: Set<String> = ["git", "npm", "pnpm", "yarn", "docker", "kubectl", "gh", "brew", "cargo", "go", "swift", "pm2", "systemctl", "adb"]
            let prefix = (multi.contains(first) && words.count > 1 && !words[1].hasPrefix("-")) ? "\(first) \(words[1])" : first
            return ("Bash(\(prefix):*)", "\(prefix) …")
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            return ("Edit", "edit file")
        default:
            return (tool, tool)
        }
    }

    /// Cocokkan permintaan dengan aturan tersimpan.
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

/// Mode izin: tanya tiap kali / selalu izinkan (dijawab otomatis oleh app) / lewati semua cek (bypassPermissions).
enum PermMode: String, CaseIterable {
    case ask, always, bypass

    var label: String {
        switch self {
        case .ask: return "Tanya dulu"
        case .always: return "Selalu izinkan"
        case .bypass: return "Lewati semua izin"
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
        case .ask: return "Kartu izin muncul untuk tiap tool yang mengubah sesuatu"
        case .always: return "Semua permintaan izin langsung disetujui otomatis"
        case .bypass: return "--dangerously-skip-permissions: Claude tidak pernah minta izin sama sekali"
        }
    }

    static var current: PermMode {
        let d = UserDefaults.standard
        if let s = d.string(forKey: "permMode"), let m = PermMode(rawValue: s) { return m }
        return d.bool(forKey: "bypassPermissions") ? .bypass : .ask   // migrasi setelan lama
    }
    static func save(_ m: PermMode) {
        UserDefaults.standard.set(m.rawValue, forKey: "permMode")
        UserDefaults.standard.removeObject(forKey: "bypassPermissions")
    }
}
