import AppKit
import SwiftUI
import Carbon.HIToolbox
import ServiceManagement
import UserNotifications

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    let model = ChatModel()
    var panel: FloatingPanel!
    var statusItem: NSStatusItem!
    var hotKeyRef: EventHotKeyRef?
    var lastSize: CGSize = .zero

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildMainMenu()
        buildPanel()
        model.onAttention = { [weak self] in
            guard let self, !self.panel.isVisible else { return }
            self.show()
        }
        model.onFinished = { [weak self] text, secs in
            guard let self, !self.panel.isVisible || !NSApp.isActive && !self.panel.isKeyWindow, secs > 8 else { return }
            self.notify(text)
        }
        setupNotifications()
        setupLoginItemOnce()
        buildStatusItem()
        registerHotKey()
        installKeyMonitor()
        show()
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            runSnapshots(dir: CommandLine.arguments[i + 1])
        }
    }

    /// Debug: render beberapa keadaan UI ke PNG (tanpa perlu izin rekam layar).
    private func runSnapshots(dir: String) {
        let md = "## Ringkasan\nIni **tebal**, `kode`, dan link https://claude.ai serta [dokumen](https://docs.claude.com).\n\n| Kota | Populasi |\n|---|---|\n| Tokyo | 37 jt |\n| Jakarta | 34 jt |\n\n```swift\nlet x = 42\n```\n> catatan kutipan"
        var waits: [String: Double] = ["b": 35, "c": 30, "d": 25, "g": 12]
        let states: [(String, () -> Void)] = [
            ("p-izin", { self.model.expanded = true; self.model.messages = [ChatMessage(role: .user, text: "cek folder")]
                self.model.permissions = [PermissionRequest(id: "x", tool: "Bash", input: ["command": "cd /tmp/nwscript && python3 nw.py | head -5"], description: "Print raw response to debug")] }),
            ("q-auto", { self.model.setPermMode(.always) }),
            ("r-bypass", { self.model.setPermMode(.bypass) }),
            ("s-ask", { self.model.setPermMode(.ask) }),
        ]
        var i = 0
        func next() {
            guard i < states.count else { NSApp.terminate(nil); return }
            let (name, apply) = states[i]; i += 1
            apply()
            DispatchQueue.main.asyncAfter(deadline: .now() + (waits[String(name.prefix(1))] ?? 2.5)) {
                guard let v = self.panel.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
                next()
            }
        }
        next()
    }

    // MARK: Panel

    private func buildPanel() {
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 700, height: 140),
                              styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                              backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self

        let root = RootView(model: model,
                            onSize: { [weak self] s in self?.resize(to: s) },
                            onClose: { [weak self] in self?.hide() })
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        WindowMover.panel = panel
        WindowMover.onEnd = { [weak self] in
            guard let f = self?.panel.frame else { return }
            UserDefaults.standard.set([f.midX, f.maxY], forKey: "panelTopCenter")
        }
        if let tc = UserDefaults.standard.array(forKey: "panelTopCenter") as? [Double], tc.count == 2,
           NSScreen.screens.contains(where: { $0.frame.contains(NSPoint(x: tc[0], y: tc[1] - 10)) }) {
            panel.setFrameTopLeftPoint(NSPoint(x: tc[0] - 350, y: tc[1]))
        } else if let scr = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: scr.midX - 350, y: scr.maxY - scr.height * 0.12))
        }
    }

    /// Ubah ukuran panel, jangkar di tengah-atas posisi sekarang.
    private func resize(to size: CGSize) {
        if CommandLine.arguments.contains("--snapshot") { print("size", size) }
        guard size.width > 10, size.height > 10, size != lastSize else { return }
        lastSize = size
        let old = panel.frame
        var f = NSRect(x: old.midX - size.width / 2, y: old.maxY - size.height,
                       width: size.width, height: size.height)
        if let scr = (panel.screen ?? NSScreen.main)?.visibleFrame {
            f.origin.x = min(max(f.origin.x, scr.minX), scr.maxX - f.width)
            if f.minY < scr.minY { f.origin.y = scr.minY }
            if f.maxY > scr.maxY + 28 { f.origin.y = scr.maxY + 28 - f.height }
        }
        panel.setFrame(f, display: true)
        panel.contentView?.frame = NSRect(origin: .zero, size: f.size)
    }

    func show() {
        if !panel.isVisible { model.captureContext() }
        Rates.shared.refreshIfStale()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        model.focusTick += 1
    }

    func hide() { panel.orderOut(nil) }

    func toggle() { panel.isVisible && panel.isKeyWindow ? hide() : show() }

    func windowDidResignKey(_ notification: Notification) {
        // Mode kecil: klik di luar = sembunyi (seperti Spotlight/Siri). Mode besar tetap mengambang.
        if !model.expanded { hide() }
    }

    // MARK: Keyboard

    private func installKeyMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if CommandLine.arguments.contains("--snapshot") { print("monitor key", e.keyCode, e.window === self?.panel); fflush(stdout) }
            guard let self, e.window === self.panel else { return e }
            let cmd = e.modifierFlags.contains(.command)
            switch (e.keyCode, cmd, e.charactersIgnoringModifiers) {
            case (53, _, _): // Esc
                if let r = self.model.permissions.first { self.model.answerPermission(r, allow: false) }
                else if self.model.busy { self.model.stop() } else { self.hide() }
                return nil
            case (36, true, _) where !self.model.permissions.isEmpty:   // ⌘Enter: izinkan
                self.model.answerPermission(self.model.permissions[0], allow: true); return nil
            case (36, true, _): self.model.send(); return nil   // ⌘Enter: paksa tanya Claude
            // Shortcut edit standar → kolom ketik (app tanpa menu Edit tidak meneruskannya sendiri)
            case (_, true, "a"): NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil); return nil
            case (_, true, "c"): NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil); return nil
            case (_, true, "v") where self.model.pasteImageIfAny(): return nil
            case (_, true, "v"): NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil); return nil
            case (_, true, "x"): NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil); return nil
            case (_, true, "z"):
                let shift = e.modifierFlags.contains(.shift)
                NSApp.sendAction(Selector(shift ? "redo:" : "undo:"), to: nil, from: nil); return nil
            case (_, true, "n"): self.model.newChat(); return nil
            case (_, true, "y"):
                if !self.model.expanded { self.model.expanded = true; self.model.showHistory = true }
                else { self.model.showHistory.toggle() }
                return nil
            case (_, true, "e"): self.model.expanded.toggle(); return nil
            case (_, true, "w"): self.hide(); return nil
            case (_, true, "t"): self.model.openInTerminal(); return nil
            default: return e
            }
        }
    }

    private var voiceHotKeyRef: EventHotKeyRef?

    private func registerHotKey() {
        // ⌥Space = buka/tutup, ⌥⇧Space = langsung bicara.
        // Ganti: defaults write id.zerodev.claudesiri hotkeyCode -int <keycode> / hotkeyMods -int <carbon mods>
        let d = UserDefaults.standard
        let code = d.object(forKey: "hotkeyCode") as? Int ?? kVK_Space
        let mods = d.object(forKey: "hotkeyMods") as? Int ?? optionKey

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, ev, ud in
            var hk = EventHotKeyID()
            GetEventParameter(ev, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let app = Unmanaged<AppDelegate>.fromOpaque(ud!).takeUnretainedValue()
            DispatchQueue.main.async { hk.id == 2 ? app.voice() : app.toggle() }
            return noErr
        }, 1, &spec, me, nil)
        RegisterEventHotKey(UInt32(code), UInt32(mods), EventHotKeyID(signature: OSType(0x434C5344), id: 1),
                            GetApplicationEventTarget(), 0, &hotKeyRef)
        RegisterEventHotKey(UInt32(code), UInt32(mods | shiftKey), EventHotKeyID(signature: OSType(0x434C5344), id: 2),
                            GetApplicationEventTarget(), 0, &voiceHotKeyRef)
    }

    func voice() {
        show()
        if !model.speech.listening { model.toggleMic() }
    }

    // MARK: Notifikasi & login

    /// Notifikasi & login item hanya jalan dari .app (bukan binary mentah saat debug).
    private var isBundled: Bool { Bundle.main.bundleIdentifier != nil }

    private func setupNotifications() {
        guard isBundled else { return }
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        c.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(_ text: String) {
        guard isBundled else { return }
        let c = UNMutableNotificationContent()
        c.title = "Claude selesai"
        c.body = String(text.replacingOccurrences(of: "\n", with: " ").prefix(180))
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler done: @escaping () -> Void) {
        DispatchQueue.main.async { self.show(); done() }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent n: UNNotification,
                                            withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    private func setupLoginItemOnce() {
        let d = UserDefaults.standard
        guard isBundled, !d.bool(forKey: "loginItemInit") else { return }
        d.set(true, forKey: "loginItemInit")
        try? SMAppService.mainApp.register()
    }

    // MARK: Menu bar

    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Keluar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit"); editItem.submenu = edit
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = main
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Claude")
        rebuildMenu()
    }

    fileprivate func rebuildMenu() {
        let d = UserDefaults.standard
        let m = statusItem.menu ?? NSMenu()
        m.removeAllItems()
        func item(_ t: String, _ sel: Selector, on: Bool? = nil, key: String = "") -> NSMenuItem {
            let i = NSMenuItem(title: t, action: sel, keyEquivalent: key)
            i.target = self
            if let on { i.state = on ? .on : .off }
            m.addItem(i)
            return i
        }
        _ = item("Buka Claude   ⌥Space", #selector(menuShow))
        _ = item("Bicara   ⌥⇧Space", #selector(menuVoice))
        _ = item("Chat baru", #selector(menuNew))
        _ = item("Riwayat chat", #selector(menuHistory))
        _ = item("Lanjutkan di Terminal", #selector(menuTerminal))
        m.addItem(.separator())

        let modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        let mm = NSMenu()
        for (id, label) in ChatModel.models {
            let i = NSMenuItem(title: label, action: #selector(pickModel(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = id
            i.state = model.modelChoice == id ? .on : .off
            mm.addItem(i)
        }
        modelItem.submenu = mm
        m.addItem(modelItem)

        let rulesItem = NSMenuItem(title: "Aturan izin (\(PermissionRules.shared.rules.count))", action: nil, keyEquivalent: "")
        let rm = NSMenu()
        if PermissionRules.shared.rules.isEmpty {
            rm.addItem(NSMenuItem(title: "Belum ada — pakai tombol \"Selalu\" di kartu izin", action: nil, keyEquivalent: ""))
        }
        for r in PermissionRules.shared.rules {
            let i = NSMenuItem(title: "✕  \(r)", action: #selector(removeRule(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = r
            rm.addItem(i)
        }
        rulesItem.submenu = rm
        m.addItem(rulesItem)
        let modeItem = NSMenuItem(title: "Mode izin: \(model.permMode.label)", action: nil, keyEquivalent: "")
        let pmMenu = NSMenu()
        for pm in PermMode.allCases {
            let i = NSMenuItem(title: pm.label, action: #selector(pickPermMode(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = pm.rawValue
            i.state = model.permMode == pm ? .on : .off
            i.toolTip = pm.detail
            pmMenu.addItem(i)
        }
        modeItem.submenu = pmMenu
        m.addItem(modeItem)
        m.addItem(.separator())

        _ = item("Sertakan teks yang dipilih" + (ScreenContext.axTrusted ? "" : " (butuh izin Aksesibilitas)"),
                 #selector(toggleSelection), on: (d.object(forKey: "grabSelection") as? Bool ?? true) && ScreenContext.axTrusted)
        _ = item("Efek kaca (Liquid Glass)", #selector(toggleGlass), on: d.object(forKey: "glass") as? Bool ?? true)
        _ = item("Bahasa suara: " + (model.speech.locale == "id-ID" ? "Indonesia" : "English"), #selector(toggleSpeechLang))
        _ = item("Jalan saat login", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled)
        _ = item("Folder kerja: \((model.workDir as NSString).abbreviatingWithTildeInPath)…", #selector(pickWorkDir))
        m.addItem(.separator())
        m.addItem(withTitle: "Keluar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        m.delegate = self
        if statusItem.menu == nil { statusItem.menu = m }
    }

    @objc private func menuVoice() { voice() }
    @objc private func menuHistory() { model.expanded = true; model.showHistory = true; show() }
    @objc private func pickModel(_ s: NSMenuItem) { model.setModel(s.representedObject as? String ?? ""); rebuildMenu() }
    @objc private func removeRule(_ s: NSMenuItem) {
        if let r = s.representedObject as? String { PermissionRules.shared.remove(r) }
        rebuildMenu()
    }
    @objc private func toggleSelection() {
        if !ScreenContext.axTrusted { ScreenContext.requestAX(); return }
        let d = UserDefaults.standard
        d.set(!(d.object(forKey: "grabSelection") as? Bool ?? true), forKey: "grabSelection")
        rebuildMenu()
    }
    @objc private func toggleGlass() {
        let d = UserDefaults.standard
        d.set(!(d.object(forKey: "glass") as? Bool ?? true), forKey: "glass")
        rebuildMenu()
    }
    @objc private func toggleSpeechLang() {
        UserDefaults.standard.set(model.speech.locale == "id-ID" ? "en-US" : "id-ID", forKey: "speechLocale")
        rebuildMenu()
    }
    @objc private func toggleLogin() {
        let svc = SMAppService.mainApp
        if svc.status == .enabled { try? svc.unregister() } else { try? svc.register() }
        rebuildMenu()
    }

    @objc private func menuShow() { show() }
    @objc private func menuNew() { model.newChat(); show() }
    @objc private func menuTerminal() { model.openInTerminal() }
    @objc private func pickPermMode(_ s: NSMenuItem) {
        if let r = s.representedObject as? String, let pm = PermMode(rawValue: r) { model.setPermMode(pm) }
        rebuildMenu()
    }
    @objc private func pickWorkDir() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.directoryURL = URL(fileURLWithPath: model.workDir)
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK, let url = p.url {
            model.workDir = url.path
            UserDefaults.standard.set(url.path, forKey: "workDir")
            model.newChat()
            rebuildMenu()
        }
    }
}

@main
struct Main {
    static func main() {
        let app = NSApplication.shared
        if CommandLine.arguments.contains("--history") {
            // Debug: daftar sesi folder home + jumlah pesan sesi teratas
            MainActor.assumeIsolated {
                let h = History.shared
                h.loadAll(workDir: NSHomeDirectory())
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    for it in h.all.prefix(6) { print(it.mine ? "★" : " ", it.date, it.title.prefix(70)) }
                    if let f = h.all.first(where: { $0.mine }) ?? h.all.first {
                        let msgs = History.loadMessages(id: f.id, workDir: f.workDir)
                        print("pesan di \(f.id):", msgs.count, msgs.prefix(4).map { ($0.user ? "U: " : "A: ") + $0.text.prefix(50) })
                    }
                    exit(0)
                }
            }
            app.run()
        }
        if let i = CommandLine.arguments.firstIndex(of: "--calc") {
            // Debug: ClaudeSiri --calc "200 usd idr" "1+2" …
            let exprs = Array(CommandLine.arguments[(i + 1)...])
            MainActor.assumeIsolated {
                Rates.shared.refresh()
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    for e in exprs {
                        if let r = Calculator.evaluate(e) {
                            print("\(e)\n   \(r.expression) | \(r.value) | \(r.secondary ?? "-") | \(r.note ?? "-") | copy=\(r.copyText)")
                        } else { print("\(e)\n   (bukan hitungan → ke Claude)") }
                    }
                    exit(0)
                }
            }
            app.run()
        }
        if #available(macOS 15.0, *), ScreenRecorder.runIfRequested() {
            app.setActivationPolicy(.prohibited)
            app.run()
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

extension AppDelegate: NSMenuDelegate {
    /// Segarkan isi menu (izin AX, aturan izin, model) tiap kali dibuka.
    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated { self.rebuildMenu() }
    }
}
