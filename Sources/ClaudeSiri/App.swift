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
    let settings = SettingsWindow()

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
        NotificationCenter.default.addObserver(forName: .hotkeyChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.registerHotKey(); self?.rebuildMenu() }
        }
        installKeyMonitor()
        show()
        firstRunCheck()
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            runSnapshots(dir: CommandLine.arguments[i + 1])
        }
    }

    /// Debug: render a few UI states to PNG with sample content (no screen recording permission needed).
    /// `ClaudeSiri --snapshot <dir>` writes 1-empty.png … 6-settings.png and quits.
    private func runSnapshots(dir: String) {
        UserDefaults.standard.set(false, forKey: "glass")   // glass renders grey offscreen
        let answer = "Here is a quick comparison:\n\n| Plan | Price | Storage |\n|---|---|---|\n| Free | $0 | 5 GB |\n| Pro | $9 | 1 TB |\n\n```sh\nswift build -c release\n```\nMore at https://github.com/zerodevid/claudesiri"
        func chat(_ q: String, _ a: String) -> [ChatMessage] {
            var m = ChatMessage(role: .assistant, text: a)
            m.stats = TurnStats(model: "claude-opus-5-5", durationMs: 6400, inputTokens: 12800, outputTokens: 240, costUSD: 0.0123)
            return [ChatMessage(role: .user, text: q), m]
        }
        let states: [(String, () -> Void)] = [
            ("1-empty", { self.model.newChat() }),
            ("2-calc", { self.model.input = "250 eur idr"; self.model.updatePreview() }),
            ("3-answer", { self.model.input = ""; self.model.messages = chat("Compare the plans", answer) }),
            ("4-permission", {
                self.model.expanded = true
                self.model.messages = chat("Clean up the build folder", "Sure, I will remove the old build output.")
                self.model.permissions = [PermissionRequest(id: "demo", tool: "Bash", input: ["command": "swift package clean"],
                                                            description: "Remove build artifacts")]
            }),
            ("5-scope", { self.model.permissions = []; self.model.setPermMode(.always, scope: .hour) }),
            ("6-settings", { self.model.setPermMode(.ask); self.openSettings() }),
        ]
        var i = 0
        func next() {
            guard i < states.count else { NSApp.terminate(nil); return }
            let (name, apply) = states[i]; i += 1
            apply()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                let win = name == "6-settings" ? NSApp.windows.first { $0.contentViewController is NSHostingController<SettingsView> } : self.panel
                guard let v = win?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { next(); return }
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
                next()
            }
        }
        next()
    }

    /// Open Settings on the first launch, or whenever the claude CLI is missing or logged out.
    private func firstRunCheck() {
        guard !CommandLine.arguments.contains("--snapshot") else { return }
        let d = UserDefaults.standard
        SetupCheck.shared.refresh { [weak self] in
            guard let self else { return }
            if !SetupCheck.shared.ready || !d.bool(forKey: "onboarded") {
                d.set(true, forKey: "onboarded")
                self.openSettings()
            }
        }
    }

    @objc func openSettings() { settings.show(model: model) }

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

    /// Resize the panel, anchored at the current top center.
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
        // Compact mode: clicking outside hides it (like Spotlight/Siri). Expanded mode keeps floating.
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
            case (36, true, _) where !self.model.permissions.isEmpty:   // ⌘Enter: allow
                self.model.answerPermission(self.model.permissions[0], allow: true); return nil
            case (36, true, _): self.model.send(); return nil   // ⌘Enter: force-ask Claude
            // Standard edit shortcuts → text field (an app without an Edit menu does not forward them itself)
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
            case (_, true, ","): self.openSettings(); return nil
            default: return e
            }
        }
    }

    private var voiceHotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerInstalled = false

    /// Register the global shortcut (default ⌥Space) and the voice shortcut (same + ⇧).
    /// Called again after the shortcut is changed in Settings.
    private func registerHotKey() {
        if let r = hotKeyRef { UnregisterEventHotKey(r); hotKeyRef = nil }
        if let r = voiceHotKeyRef { UnregisterEventHotKey(r); voiceHotKeyRef = nil }
        let key = Hotkey.current

        if !hotKeyHandlerInstalled {
            hotKeyHandlerInstalled = true
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
        }
        RegisterEventHotKey(UInt32(key.code), UInt32(key.mods), EventHotKeyID(signature: OSType(0x434C5344), id: 1),
                            GetApplicationEventTarget(), 0, &hotKeyRef)
        if key.mods & shiftKey == 0 {
            RegisterEventHotKey(UInt32(key.code), UInt32(key.mods | shiftKey), EventHotKeyID(signature: OSType(0x434C5344), id: 2),
                                GetApplicationEventTarget(), 0, &voiceHotKeyRef)
        }
    }

    func voice() {
        show()
        if !model.speech.listening { model.toggleMic() }
    }

    // MARK: Notifications & login

    /// Notifications and the login item only work from the .app (not the raw debug binary).
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
        c.title = tr("Claude is done", "Claude selesai")
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
        appMenu.addItem(withTitle: tr("Quit ClaudeSiri", "Keluar"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
        let m = statusItem.menu ?? NSMenu()
        m.removeAllItems()
        func item(_ t: String, _ sel: Selector, key: String = "") {
            let i = NSMenuItem(title: t, action: sel, keyEquivalent: key)
            i.target = self
            m.addItem(i)
        }
        let hk = Hotkey.current
        item(tr("Open Claude", "Buka Claude") + "   " + hk.display, #selector(menuShow))
        if hk.mods & shiftKey == 0 { item(tr("Talk", "Bicara") + "   " + hk.voiceDisplay, #selector(menuVoice)) }
        item(tr("New chat", "Chat baru"), #selector(menuNew))
        item(tr("Chat history", "Riwayat chat"), #selector(menuHistory))
        item(tr("Continue in Terminal", "Lanjutkan di Terminal"), #selector(menuTerminal))
        m.addItem(.separator())
        if model.permMode != .ask {
            let i = NSMenuItem(title: tr("Permission mode: ", "Mode izin: ") + model.permMode.label + " · " + tr("switch to Ask first", "ganti ke Tanya dulu"),
                               action: #selector(menuAskFirst), keyEquivalent: "")
            i.target = self
            m.addItem(i)
        }
        item(tr("Settings…", "Pengaturan…"), #selector(openSettings), key: ",")
        m.addItem(.separator())
        m.addItem(withTitle: tr("Quit ClaudeSiri", "Keluar"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        m.delegate = self
        if statusItem.menu == nil { statusItem.menu = m }
    }

    @objc private func menuVoice() { voice() }
    @objc private func menuHistory() { model.expanded = true; model.showHistory = true; show() }
    @objc private func menuAskFirst() { model.setPermMode(.ask) }

    @objc private func menuShow() { show() }
    @objc private func menuNew() { model.newChat(); show() }
    @objc private func menuTerminal() { model.openInTerminal() }
}

@main
struct Main {
    static func main() {
        let app = NSApplication.shared
        if CommandLine.arguments.contains("--history") {
            // Debug: list sessions for the home folder + message count of the newest one
            MainActor.assumeIsolated {
                let h = History.shared
                h.loadAll(workDir: NSHomeDirectory())
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    for it in h.all.prefix(6) { print(it.mine ? "★" : " ", it.date, it.title.prefix(70)) }
                    if let f = h.all.first(where: { $0.mine }) ?? h.all.first {
                        let msgs = History.loadMessages(id: f.id, workDir: f.workDir)
                        print("messages in \(f.id):", msgs.count, msgs.prefix(4).map { ($0.user ? "U: " : "A: ") + $0.text.prefix(50) })
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
                        } else { print("\(e)\n   (not math → goes to Claude)") }
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
    /// Refresh the menu (AX permission, permission rules, model) every time it opens.
    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated { self.rebuildMenu() }
    }
}
