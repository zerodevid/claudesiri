import SwiftUI
import AppKit
import Carbon.HIToolbox
import AVFoundation
import Speech
import ServiceManagement

extension Notification.Name {
    /// Posted after the global hotkey was changed in Settings.
    static let hotkeyChanged = Notification.Name("ClaudeSiri.hotkeyChanged")
}

// MARK: - Hotkey

/// The global shortcut stored as a virtual key code + Carbon modifier mask.
struct Hotkey: Equatable {
    var code: Int
    var mods: Int

    static let fallback = Hotkey(code: kVK_Space, mods: optionKey)

    static var current: Hotkey {
        let d = UserDefaults.standard
        return Hotkey(code: d.object(forKey: "hotkeyCode") as? Int ?? fallback.code,
                      mods: d.object(forKey: "hotkeyMods") as? Int ?? fallback.mods)
    }

    func save() {
        UserDefaults.standard.set(code, forKey: "hotkeyCode")
        UserDefaults.standard.set(mods, forKey: "hotkeyMods")
        NotificationCenter.default.post(name: .hotkeyChanged, object: nil)
    }

    /// Carbon modifier mask from an NSEvent's flags.
    static func carbonMods(_ f: NSEvent.ModifierFlags) -> Int {
        var m = 0
        if f.contains(.command) { m |= cmdKey }
        if f.contains(.option) { m |= optionKey }
        if f.contains(.control) { m |= controlKey }
        if f.contains(.shift) { m |= shiftKey }
        return m
    }

    var display: String {
        var s = ""
        if mods & controlKey != 0 { s += "⌃" }
        if mods & optionKey != 0 { s += "⌥" }
        if mods & shiftKey != 0 { s += "⇧" }
        if mods & cmdKey != 0 { s += "⌘" }
        return s + Self.keyName(code)
    }

    /// The voice shortcut is the main shortcut plus Shift.
    var voiceDisplay: String { Hotkey(code: code, mods: mods | shiftKey).display }

    static func keyName(_ code: Int) -> String {
        let named: [Int: String] = [kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋",
                                    kVK_Delete: "⌫", kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_LeftArrow: "←",
                                    kVK_RightArrow: "→", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
                                    kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9",
                                    kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"]
        if let n = named[code] { return n }
        // Ask the current keyboard layout which character this key types.
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return "#\(code)" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var len = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
        }
        guard status == noErr, len > 0 else { return "#\(code)" }
        return String(utf16CodeUnits: chars, count: len).uppercased()
    }
}

/// Click, then press the new shortcut. Needs at least one of ⌘ ⌥ ⌃.
struct HotkeyRecorder: View {
    @State private var key = Hotkey.current
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 10) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? tr("Press a shortcut…", "Tekan shortcut…") : key.display)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .frame(minWidth: 120)
            }
            if key != Hotkey.fallback {
                Button(tr("Reset", "Kembalikan")) { key = Hotkey.fallback; key.save() }
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == UInt16(kVK_Escape) { stop(); return nil }
            let mods = Hotkey.carbonMods(e.modifierFlags)
            guard mods & (cmdKey | optionKey | controlKey) != 0 else { NSSound.beep(); return nil }
            key = Hotkey(code: Int(e.keyCode), mods: mods)
            key.save()
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}

// MARK: - Setup check

/// What ClaudeSiri needs: the claude CLI, a login, and (optional) macOS permissions.
@MainActor
final class SetupCheck: ObservableObject {
    static let shared = SetupCheck()

    @Published private(set) var claudePath: String?
    @Published private(set) var loggedIn: Bool?
    @Published private(set) var authMethod: String?
    @Published private(set) var checking = false
    @Published private(set) var accessibility = false
    @Published private(set) var screenRecording = false
    @Published private(set) var microphone = false
    @Published private(set) var speech = false

    /// Ready to chat: CLI found and logged in.
    var ready: Bool { claudePath != nil && loggedIn == true }

    func refresh(completion: (() -> Void)? = nil) {
        accessibility = AXIsProcessTrusted()
        screenRecording = CGPreflightScreenCaptureAccess()
        microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        speech = SFSpeechRecognizer.authorizationStatus() == .authorized
        claudePath = ClaudeRunner.claudePath()
        guard let path = claudePath else { loggedIn = false; authMethod = nil; completion?(); return }
        checking = true
        let env = ClaudeRunner.environment()
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = ["auth", "status"]
            p.environment = env
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            var ok: Bool?
            var method: String?
            if (try? p.run()) != nil {
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                if let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    ok = o["loggedIn"] as? Bool
                    method = o["authMethod"] as? String
                } else {
                    ok = p.terminationStatus == 0
                }
            }
            let (result, how) = (ok, method)
            await MainActor.run {
                self.loggedIn = result ?? false
                self.authMethod = how
                self.checking = false
                completion?()
            }
        }
    }

    static func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Settings window

struct SettingsView: View {
    @ObservedObject var model: ChatModel
    @ObservedObject var setup = SetupCheck.shared
    @ObservedObject var rules = PermissionRules.shared
    @AppStorage("uiLanguage") private var language = "system"
    @AppStorage("glass") private var glass = true
    @AppStorage("grabSelection") private var grabSelection = true
    @AppStorage("speechLocale") private var speechLocale = "id-ID"
    @AppStorage("claudePath") private var claudePathSetting = ""
    @AppStorage("claudeConfigDir") private var configDir = ""
    @AppStorage("idleMinutes") private var idleMinutes = 10.0
    @State private var loginItem = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            setupSection
            Section(tr("General", "Umum")) {
                Picker(tr("Language", "Bahasa"), selection: $language) {
                    ForEach(UILanguage.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                }
                LabeledContent(tr("Open ClaudeSiri", "Buka ClaudeSiri")) { HotkeyRecorder() }
                LabeledContent(tr("Talk", "Bicara")) {
                    Text(tr("Same shortcut + ⇧", "Shortcut yang sama + ⇧")).foregroundStyle(.secondary)
                }
                Toggle(tr("Launch at login", "Jalan saat login"), isOn: $loginItem)
                    .onChange(of: loginItem) { _, on in
                        let svc = SMAppService.mainApp
                        if on { try? svc.register() } else { try? svc.unregister() }
                    }
                if #available(macOS 26.0, *) {
                    Toggle(tr("Liquid Glass effect", "Efek kaca (Liquid Glass)"), isOn: $glass)
                }
                Toggle(tr("Include text selected in other apps", "Sertakan teks yang dipilih di app lain"), isOn: $grabSelection)
                Picker(tr("Voice input language", "Bahasa input suara"), selection: $speechLocale) {
                    Text("Bahasa Indonesia").tag("id-ID")
                    Text("English").tag("en-US")
                }
            }
            Section("Claude") {
                Picker("Model", selection: Binding(get: { model.modelChoice }, set: { model.setModel($0) })) {
                    ForEach(ChatModel.models, id: \.id) { Text($0.label).tag($0.id) }
                }
                LabeledContent(tr("Working folder", "Folder kerja")) {
                    HStack {
                        Text((model.workDir as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                        Button(tr("Choose…", "Pilih…")) { chooseWorkDir() }
                    }
                }
                TextField(tr("Config folder", "Folder config"), text: $configDir, prompt: Text("~/.claude"))
                TextField(tr("claude CLI path", "Path CLI claude"), text: $claudePathSetting,
                          prompt: Text(setup.claudePath ?? tr("auto-detect", "deteksi otomatis")))
                Stepper(value: $idleMinutes, in: 0...120, step: 5) {
                    Text(idleMinutes == 0 ? tr("Keep idle chats running", "Biarkan chat menganggur tetap jalan")
                         : tr("Close idle chats after \(Int(idleMinutes)) min", "Tutup chat menganggur setelah \(Int(idleMinutes)) mnt"))
                }
            }
            Section(tr("Permissions", "Izin")) {
                Picker(tr("Mode", "Mode"), selection: Binding(get: { model.permMode }, set: { model.setPermMode($0, scope: model.permScope) })) {
                    ForEach(PermMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if model.permMode != .ask {
                    Picker(tr("Lasts", "Berlaku"), selection: Binding(get: { model.permScope }, set: { model.setPermMode(model.permMode, scope: $0) })) {
                        ForEach(PermScope.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
                Text(model.permMode.detail).font(.caption).foregroundStyle(.secondary)
                if rules.rules.isEmpty {
                    Text(tr("No saved rules yet. Use \"Always\" on a permission card.", "Belum ada aturan tersimpan. Pakai tombol \"Selalu\" di kartu izin."))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(rules.rules, id: \.self) { r in
                        HStack {
                            Text(r).font(.system(.body, design: .monospaced))
                            Spacer()
                            Button(role: .destructive) { rules.remove(r) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 500, minHeight: 480)
        .id(language)
        .onAppear { setup.refresh(); loginItem = SMAppService.mainApp.status == .enabled }
        .onChange(of: claudePathSetting) { setup.refresh() }
        .onChange(of: configDir) { setup.refresh() }
    }

    @ViewBuilder private var setupSection: some View {
        Section {
            row(ok: setup.claudePath != nil, tr("Claude Code CLI", "CLI Claude Code"),
                detail: setup.claudePath.map { ($0 as NSString).abbreviatingWithTildeInPath }
                    ?? tr("Not found. Install Claude Code, or set the path below.", "Tidak ketemu. Pasang Claude Code, atau isi path di bawah.")) {
                Button(tr("Install guide", "Cara pasang")) {
                    NSWorkspace.shared.open(URL(string: "https://docs.claude.com/en/docs/claude-code/setup")!)
                }
            }
            row(ok: setup.loggedIn == true, tr("Logged in", "Sudah login"),
                detail: setup.checking ? tr("Checking…", "Memeriksa…")
                    : setup.loggedIn == true ? (setup.authMethod ?? "")
                    : tr("Run `claude` in Terminal once and log in.", "Jalankan `claude` sekali di Terminal lalu login.")) {
                Button(tr("Open Terminal", "Buka Terminal")) { model.openInTerminal() }
            }
            row(ok: setup.accessibility, tr("Accessibility (optional)", "Aksesibilitas (opsional)"),
                detail: tr("To include selected text", "Untuk menyertakan teks terpilih")) {
                Button(tr("Allow…", "Izinkan…")) { ScreenContext.requestAX(); SetupCheck.openPrivacy("Privacy_Accessibility") }
            }
            row(ok: setup.screenRecording, tr("Screen Recording (optional)", "Screen Recording (opsional)"),
                detail: tr("For window screenshots", "Untuk screenshot jendela")) {
                Button(tr("Allow…", "Izinkan…")) { CGRequestScreenCaptureAccess(); SetupCheck.openPrivacy("Privacy_ScreenCapture") }
            }
            row(ok: setup.microphone && setup.speech, tr("Microphone + Speech (optional)", "Mikrofon + Ucapan (opsional)"),
                detail: tr("For voice input", "Untuk input suara")) {
                Button(tr("Allow…", "Izinkan…")) {
                    AVCaptureDevice.requestAccess(for: .audio) { _ in
                        SFSpeechRecognizer.requestAuthorization { _ in DispatchQueue.main.async { SetupCheck.shared.refresh() } }
                    }
                }
            }
        } header: {
            HStack {
                Text(tr("Setup", "Persiapan"))
                Spacer()
                Button(tr("Check again", "Periksa lagi")) { setup.refresh() }.buttonStyle(.link).font(.caption)
            }
        }
    }

    private func row<B: View>(ok: Bool, _ title: String, detail: String, @ViewBuilder button: () -> B) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ok ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if !ok { button() }
        }
    }

    private func chooseWorkDir() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.directoryURL = URL(fileURLWithPath: model.workDir)
        if p.runModal() == .OK, let url = p.url {
            model.workDir = url.path
            UserDefaults.standard.set(url.path, forKey: "workDir")
            model.newChat()
        }
    }
}

/// Hosts SettingsView in a normal titled window.
@MainActor
final class SettingsWindow {
    private var window: NSWindow?

    func show(model: ChatModel) {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            w.title = tr("ClaudeSiri Settings", "Pengaturan ClaudeSiri")
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 540, height: 720))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.title = tr("ClaudeSiri Settings", "Pengaturan ClaudeSiri")
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
