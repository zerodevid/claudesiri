import SwiftUI
import AppKit

enum Theme {
    static let corner: CGFloat = 34
    static let shell = LinearGradient(colors: [Color(white: 0.17), Color(white: 0.09)],
                                      startPoint: .top, endPoint: .bottom)
    static let inner = Color.black
    static let border = Color.white.opacity(0.13)
    static let dim = Color(white: 0.55)
    static let glow: [Color] = [.blue, .purple, .pink, .orange, .cyan, .blue]
    static let accent = Color(red: 0.85, green: 0.47, blue: 0.34) // Claude orange
}

/// Content size is reported to AppDelegate so the panel grows and shrinks with it.
struct SizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

struct RootView: View {
    @ObservedObject var model: ChatModel
    var onSize: (CGSize) -> Void
    var onClose: () -> Void
    @AppStorage("uiLanguage") private var language = "system"

    var body: some View {
        Group {
            if model.expanded {
                ExpandedView(model: model, onClose: onClose)
                    .frame(width: model.showHistory ? 1010 : 760, height: 660)
            } else {
                CompactView(model: model, onClose: onClose)
                    .frame(width: 640)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .id(language)   // rebuild every view when the UI language changes
        .padding(28) // room for the shadow and glow
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
            for pr in providers {
                if pr.canLoadObject(ofClass: URL.self) {
                    _ = pr.loadObject(ofClass: URL.self) { url, _ in
                        if let url, let img = NSImage(contentsOf: url) {
                            DispatchQueue.main.async { model.addImages([img]) }
                        }
                    }
                } else if pr.canLoadObject(ofClass: NSImage.self) {
                    _ = pr.loadObject(ofClass: NSImage.self) { img, _ in
                        if let img = img as? NSImage { DispatchQueue.main.async { model.addImages([img]) } }
                    }
                }
            }
            return true
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Components

struct CircleButton: View {
    let symbol: String
    var size: CGFloat = 44
    var tint: Color = .white
    var help: String = ""
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.4, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.white.opacity(hover ? 0.2 : 0.11)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

struct GlowBorder: View {
    let active: Bool
    let corner: CGFloat
    @State private var angle = 0.0

    var body: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .strokeBorder(AngularGradient(colors: Theme.glow, center: .center, angle: .degrees(angle)), lineWidth: 3)
            .blur(radius: 6)
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(AngularGradient(colors: Theme.glow, center: .center, angle: .degrees(angle)), lineWidth: 1.5)
            )
            .opacity(active ? 1 : 0)
            .animation(.easeInOut(duration: 0.4), value: active)
            .onAppear {
                withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) { angle = 360 }
            }
            .allowsHitTesting(false)
    }
}

struct Shell<Content: View>: View {
    let busy: Bool
    var corner: CGFloat = Theme.corner
    @ViewBuilder let content: Content
    @AppStorage("glass") private var glass = true

    var body: some View {
        if #available(macOS 26.0, *), glass {
            content
                .foregroundStyle(Color(white: 0.95))
                .environment(\.colorScheme, .dark)
                .background(
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .fill(Color.black.opacity(0.42))
                        .windowDrag()
                )
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
                .overlay(GlowBorder(active: busy, corner: corner))
        } else {
            solid
        }
    }

    private var solid: some View {
        content
            .background(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Theme.shell)
                    .shadow(color: .black.opacity(0.55), radius: 22, y: 10)
                    .windowDrag()
            )
            .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(Theme.border))
            .overlay(GlowBorder(active: busy, corner: corner))
    }
}

/// Capsule-shaped input field.
struct InputPill: View {
    @ObservedObject var model: ChatModel
    var placeholder = tr("Ask Claude", "Tanya Claude")
    var big = false
    @FocusState.Binding var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Button { model.pickImages() } label: {
                Image(systemName: "photo.badge.plus").font(.system(size: big ? 20 : 16)).foregroundStyle(Theme.dim)
            }
            .buttonStyle(.plain)
            .help(tr("Attach an image (or ⌘V / drop one here)", "Lampirkan gambar (atau ⌘V / seret gambar ke sini)"))
            if let app = model.contextAppName {
                Button { model.attachWindowShot() } label: {
                    ZStack(alignment: .bottomTrailing) {
                        if let icon = model.contextApp?.icon {
                            Image(nsImage: icon).resizable().interpolation(.high)
                                .frame(width: big ? 26 : 22, height: big ? 26 : 22)
                        } else {
                            Image(systemName: "macwindow").font(.system(size: big ? 19 : 16)).foregroundStyle(Theme.dim)
                                .frame(width: big ? 26 : 22, height: big ? 26 : 22)
                        }
                        Image(systemName: "camera.fill")
                            .font(.system(size: big ? 8 : 7, weight: .bold)).foregroundStyle(.white)
                            .frame(width: big ? 14 : 12, height: big ? 14 : 12)
                            .background(Circle().fill(Color(white: 0.2)))
                            .overlay(Circle().strokeBorder(Color.black.opacity(0.6), lineWidth: 1))
                            .offset(x: 3, y: 3)
                    }
                    .padding(.trailing, 5)
                }
                .buttonStyle(.plain)
                .help(tr("Attach a screenshot of the \(app) window", "Lampirkan screenshot jendela \(app)"))
            }
            TextField("", text: $model.input, prompt: Text(placeholder).foregroundColor(Theme.dim), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: big ? 24 : 17))
                .lineLimit(1...6)
                .focused($focused)
                .onSubmit { model.submit() }
            if model.busy {
                trailing("stop.fill", tint: .white) { model.stop() }
            } else if !model.input.trimmingCharacters(in: .whitespaces).isEmpty || !model.attachments.isEmpty {
                trailing("arrow.up", tint: .black, fill: .white) { model.send() }
            } else if model.speech.listening {
                Button { model.speech.finish() } label: {
                    Image(systemName: "waveform")
                        .font(.system(size: big ? 20 : 16, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.red.opacity(0.85)))
                        .scaleEffect(1 + CGFloat(model.speech.level) * 0.25)
                        .animation(.easeOut(duration: 0.1), value: model.speech.level)
                }
                .buttonStyle(.plain)
                .help(tr("Done talking (sends automatically after a pause)", "Selesai bicara (otomatis terkirim setelah diam)"))
            } else {
                Button { model.toggleMic() } label: {
                    Image(systemName: "mic").font(.system(size: big ? 22 : 17)).foregroundStyle(Theme.dim)
                }
                .buttonStyle(.plain)
                .help(tr("Talk (⌥⇧Space)", "Bicara (⌥⇧Space)"))
            }
        }
        .padding(.horizontal, big ? 30 : 20)
        .padding(.vertical, big ? 22 : 13)
        .background(
            Capsule(style: .continuous)
                .fill(big ? AnyShapeStyle(LinearGradient(colors: [Color(white: 0.05), Color(white: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing))
                          : AnyShapeStyle(Color.white.opacity(0.09)))
        )
        .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(big ? 0.12 : 0.07)))
        .contentShape(Capsule())
        .onTapGesture { focused = true }
        .windowDrag()
    }

    private func trailing(_ s: String, tint: Color, fill: Color = Color.white.opacity(0.15), action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: s).font(.system(size: 13, weight: .bold)).foregroundStyle(tint)
                .frame(width: 30, height: 30).background(Circle().fill(fill))
        }.buttonStyle(.plain)
    }
}

/// Spotlight/Siri-style card for a calculation/conversion result.
struct CalcCard: View {
    let result: CalcResult
    var big: CGFloat = 46
    @State private var copied = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(result.expression).font(.system(size: 15)).foregroundStyle(Theme.dim).lineLimit(2)
                Text(result.value)
                    .font(.system(size: big, weight: .regular))
                    .foregroundStyle(Color(white: 0.92))
                    .lineLimit(1).minimumScaleFactor(0.4)
                    .textSelection(.enabled)
                if let s = result.secondary {
                    Text(s).font(.system(size: 15)).foregroundStyle(Color(white: 0.7))
                }
                if let n = result.note {
                    Text(n).font(.system(size: 11)).foregroundStyle(Theme.dim).padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
            CircleButton(symbol: copied ? "checkmark" : "doc.on.doc.fill", size: 34, tint: .blue, help: tr("Copy number", "Salin angka")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.copyText, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Theme.inner))
    }
}

/// Row of thumbnails for the images about to be sent.
struct AttachmentStrip: View {
    @ObservedObject var model: ChatModel
    var body: some View {
        if !model.attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(model.attachments) { a in
                        Image(nsImage: a.image).resizable().scaledToFill()
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.15)))
                            .overlay(alignment: .topTrailing) {
                                Button { model.attachments.removeAll { $0.id == a.id } } label: {
                                    Image(systemName: "xmark.circle.fill").font(.system(size: 16))
                                        .symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.7))
                                }.buttonStyle(.plain).offset(x: 5, y: -5)
                            }
                    }
                }
                .padding(.top, 6).padding(.horizontal, 4)
            }
        }
    }
}

/// Permission card: Deny / Allow / Always.
struct PermissionCard: View {
    @ObservedObject var model: ChatModel
    let req: PermissionRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                Text(tr("Claude asks permission · \(req.tool)", "Claude minta izin · \(req.tool)")).font(.system(size: 14, weight: .semibold))
                Spacer()
                if model.permissions.count > 1 {
                    Text(tr("+\(model.permissions.count - 1) queued", "+\(model.permissions.count - 1) antre")).font(.system(size: 12)).foregroundStyle(Theme.dim)
                }
            }
            Text(req.title).font(.system(size: 14)).foregroundStyle(Color(white: 0.85))
            if !req.detail.isEmpty {
                ScrollView {
                    Text(req.detail)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color(white: 0.85))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 150)
                .fixedSize(horizontal: false, vertical: true)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
            }
            HStack(spacing: 10) {
                pill(tr("Deny", "Tolak"), fg: .white, bg: Color.white.opacity(0.12)) { model.answerPermission(req, allow: false) }
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                if let label = req.ruleLabel {
                    pill(tr("Always: \(label)", "Selalu: \(label)"), fg: .white, bg: Color.white.opacity(0.12)) {
                        model.answerPermission(req, allow: true, always: true)
                    }
                    .help(tr("Save the rule \(req.ruleSuggestion ?? "") (remove it in Settings › Permissions)", "Simpan aturan \(req.ruleSuggestion ?? "") (bisa dihapus di Pengaturan › Izin)"))
                }
                pill(tr("Allow all", "Izinkan semua"), fg: .white, bg: Color.white.opacity(0.12)) { model.setPermMode(.always, scope: .chat) }
                    .help(tr("Approve this and every later request without asking (Always allow mode, for this chat)", "Setujui ini dan semua permintaan berikutnya tanpa tanya (mode Selalu izinkan, untuk chat ini)"))
                pill(tr("Allow", "Izinkan"), fg: .black, bg: .white) { model.answerPermission(req, allow: true) }
                    .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.inner))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.orange.opacity(0.45)))
    }

    private func pill(_ t: String, fg: Color, bg: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(.system(size: 13, weight: .semibold)).foregroundStyle(fg)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(bg))
        }.buttonStyle(.plain)
    }
}

/// Context chip: the text currently selected in another app.
struct SelectionChip: View {
    @ObservedObject var model: ChatModel
    var body: some View {
        if let sel = model.selected {
            HStack(spacing: 8) {
                Image(systemName: "text.quote").foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tr("Selected text · \(sel.app)", "Teks terpilih · \(sel.app)")).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.dim)
                    Text(sel.text.replacingOccurrences(of: "\n", with: " ")).font(.system(size: 12))
                        .foregroundStyle(Color(white: 0.85)).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button { model.selected = nil } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.dim)
                }.buttonStyle(.plain).help(tr("Don't include", "Jangan sertakan"))
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.07)))
        }
    }
}

/// Small line under an answer: model · time · tokens · cost.
struct StatsLine: View {
    let stats: TurnStats
    var body: some View {
        Text(Self.format(stats)).font(.system(size: 11)).foregroundStyle(Color(white: 0.42))
    }
    static func modelName(_ id: String?) -> String? {
        guard var m = id else { return nil }
        if m.hasPrefix("claude-") { m.removeFirst(7) }
        var parts = m.split(separator: "-").map(String.init)
        guard !parts.isEmpty else { return m }
        let name = parts.removeFirst().capitalized
        return parts.isEmpty ? name : name + " " + parts.prefix(2).joined(separator: ".")
    }
    static func tokens(_ n: Int) -> String {
        guard n >= 1000 else { return "\(n)" }
        let s = String(format: "%.1f", Double(n) / 1000)
        return UILanguage.isIndonesian ? s.replacingOccurrences(of: ".", with: ",") + "rb" : s + "k"
    }
    static func format(_ s: TurnStats) -> String {
        var parts: [String] = []
        if let m = modelName(s.model) { parts.append(m) }
        let secs = String(format: "%.1f", Double(s.durationMs) / 1000)
        parts.append(UILanguage.isIndonesian ? secs.replacingOccurrences(of: ".", with: ",") + " dtk" : secs + " s")
        parts.append("\(tokens(s.inputTokens)) → \(tokens(s.outputTokens)) " + tr("tokens", "token"))
        if s.costUSD > 0 { parts.append(String(format: "$%.4f", s.costUSD)) }
        return parts.joined(separator: " · ")
    }
}

/// Small model picker.
struct ModelMenu: View {
    @ObservedObject var model: ChatModel
    var body: some View {
        Menu {
            ForEach(ChatModel.models, id: \.id) { m in
                Button { model.setModel(m.id) } label: {
                    if model.modelChoice == m.id { Label(m.label, systemImage: "checkmark") } else { Text(m.label) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(ChatModel.models.first { $0.id == model.modelChoice }?.label ?? model.modelChoice)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .font(.system(size: 12, weight: .medium)).foregroundStyle(Color(white: 0.75))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(0.1)))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help(tr("Choose model", "Pilih model"))
    }
}

/// Permission mode picker: Ask first / Always allow / Skip all permissions.
struct PermModeMenu: View {
    @ObservedObject var model: ChatModel
    var body: some View {
        let m = model.permMode
        Menu {
            Button { model.setPermMode(.ask) } label: {
                Label(PermMode.ask.label + (m == .ask ? "  ✓" : ""), systemImage: PermMode.ask.symbol)
            }
            ForEach([PermMode.always, .bypass], id: \.self) { opt in
                Menu {
                    ForEach(PermScope.allCases, id: \.self) { sc in
                        Button(sc.label + (opt == m && sc == model.permScope ? "  ✓" : "")) { model.setPermMode(opt, scope: sc) }
                    }
                } label: {
                    Label(opt.label + (opt == m ? "  ✓" : ""), systemImage: opt.symbol)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: m.symbol).font(.system(size: 11, weight: .semibold))
                if m != .ask {
                    Text(m == .always ? "Auto" : "Bypass")
                    if let s = scopeBadge { Text(s).opacity(0.7) }
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(m == .ask ? Color(white: 0.75) : m == .always ? Color.orange : Color(red: 1, green: 0.42, blue: 0.4))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Capsule().fill(m == .bypass ? Color.red.opacity(0.18) : Color.white.opacity(0.1)))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help(tr("Permission mode", "Mode izin") + ": \(m.label) — \(m.detail)")
    }

    /// "chat" or minutes left for a scoped automatic mode.
    private var scopeBadge: String? {
        switch model.permScope {
        case .chat: return tr("· chat", "· chat")
        case .hour:
            guard let u = model.permUntil else { return nil }
            return "· \(max(1, Int(u.timeIntervalSinceNow / 60)))m"
        case .always: return nil
        }
    }
}

/// Chat history sidebar.
struct HistoryList: View {
    @ObservedObject var model: ChatModel
    @ObservedObject var history = History.shared
    @State private var showAll = false
    @State private var query = ""

    private var items: [SessionInfo] {
        let base = showAll ? history.all : history.mine.filter { $0.workDir == model.workDir }
        guard !query.isEmpty else { return base }
        return base.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $showAll) {
                Text("ClaudeSiri").tag(false)
                Text(tr("All sessions", "Semua sesi")).tag(true)
            }
            .pickerStyle(.segmented).labelsHidden()
            .onChange(of: showAll) { _, v in if v { history.loadAll(workDir: model.workDir) } }
            TextField(tr("Search…", "Cari…"), text: $query).textFieldStyle(.plain).font(.system(size: 13))
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.07)))
            if showAll && history.loadingAll { ProgressView().controlSize(.small) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if items.isEmpty {
                        Text(tr("No history yet", "Belum ada riwayat")).font(.system(size: 12)).foregroundStyle(Theme.dim).padding(.top, 8)
                    }
                    ForEach(items) { it in
                        Button { model.loadSession(it) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(it.title).font(.system(size: 13)).lineLimit(2).multilineTextAlignment(.leading)
                                    .foregroundStyle(it.id == model.sessionID ? Theme.accent : Color(white: 0.9))
                                Text(it.date, format: .relative(presentation: .named))
                                    .font(.system(size: 11)).foregroundStyle(Theme.dim)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 9).fill(it.id == model.sessionID ? Color.white.opacity(0.08) : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(tr("Continue in Terminal", "Lanjutkan di Terminal")) { model.loadSession(it); model.openInTerminal() }
                            if it.mine { Button(tr("Remove from list", "Hapus dari daftar")) { history.forget(it.id) } }
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 250)
        .background(Color.black.opacity(0.25))
    }
}

/// Small text button under an answer.
struct QuickAction: View {
    let symbol: String
    let title: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(hover ? Color.white : Color(white: 0.7))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(hover ? 0.16 : 0.08)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .lineLimit(1)
    }
}

struct ToolLine: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).scaleEffect(0.7)
            Text(text).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.dim).lineLimit(1)
        }
    }
}

struct ThinkingDots: View {
    @State private var on = false
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3) { i in
                Circle().fill(Color.white.opacity(0.7)).frame(width: 7, height: 7)
                    .scaleEffect(on ? 1 : 0.4)
                    .animation(.easeInOut(duration: 0.55).repeatForever().delay(Double(i) * 0.18), value: on)
            }
        }
        .onAppear { on = true }
    }
}

// MARK: - Compact mode (Siri)

struct CompactView: View {
    @ObservedObject var model: ChatModel
    var onClose: () -> Void   // Esc / click outside close the compact panel
    @State private var textHeight: CGFloat = 20
    @FocusState private var focused: Bool

    private var hasChat: Bool { !model.messages.isEmpty }
    var body: some View {
        Group {
            if !hasChat {
                // One fixed structure (the pill always in the same place) so the TextField is not recreated
                // when the result card or attachments appear; recreating it loses keyboard focus.
                let extras = !model.attachments.isEmpty || model.selected != nil || model.speech.error != nil
                let calc = extras ? nil : model.preview
                let bare = !extras && calc == nil
                Shell(busy: model.busy || model.speech.listening, corner: bare ? 50 : Theme.corner) {
                    VStack(alignment: .leading, spacing: bare ? 0 : (extras ? 10 : 12)) {
                        if extras {
                            if let e = model.speech.error {
                                Text(e).font(.system(size: 12)).foregroundStyle(.orange).padding(.horizontal, 8)
                            }
                            SelectionChip(model: model)
                            AttachmentStrip(model: model)
                        }
                        InputPill(model: model,
                                  placeholder: model.selected != nil ? tr("Ask about this text", "Tanya soal teks ini")
                                      : !model.attachments.isEmpty ? tr("Ask about this image", "Tanya soal gambar ini")
                                      : tr("Search or ask Claude", "Cari atau Tanya Claude"),
                                  big: true, focused: $focused)
                        if let p = calc { CalcCard(result: p) }
                    }
                    .padding(bare ? 0 : 12)
                }
            } else {
                Shell(busy: model.busy || model.speech.listening) {
                    // Fixed layout: nothing appears or disappears on hover. Hover-driven controls resized the
                    // panel, which moved the edge under the cursor and made the panel bounce up and down.
                    VStack(alignment: .leading, spacing: 16) {
                        if let q = model.lastUser {
                            Text((q.images.isEmpty ? "" : "🖼 \(q.images.count) · ") + q.text).font(.system(size: 13)).foregroundStyle(Theme.dim).lineLimit(2)
                                .padding(.horizontal, 6)
                        }

                        answerCard

                        if let req = model.permissions.first {
                            PermissionCard(model: model, req: req)
                        }

                        SelectionChip(model: model)
                        AttachmentStrip(model: model)
                        HStack(spacing: 12) {
                            CircleButton(symbol: "plus", help: tr("New chat (⌘N)", "Chat baru (⌘N)")) { model.newChat() }
                            InputPill(model: model, focused: $focused)
                            CircleButton(symbol: "arrow.up.left.and.arrow.down.right", help: tr("Expand (⌘E)", "Perbesar (⌘E)")) {
                                model.expanded = true
                            }
                        }
                    }
                    .padding(22)
                }
            }
        }
        .animation(.spring(duration: 0.3), value: model.messages.count)
        .onAppear { focused = true }
        .onChange(of: model.focusTick) { focused = true }
        .onChange(of: model.busy) { _, b in if !b { focused = true } }   // ready for a follow-up
    }

    @ViewBuilder private var answerCard: some View {
        if let p = model.preview {
            CalcCard(result: p)
        } else if let c = model.lastAssistant?.calc {
            CalcCard(result: c)
        } else if let a = model.lastAssistant {
            VStack(alignment: .leading, spacing: 10) {
                if a.text.isEmpty {
                    if let t = model.currentTool { ToolLine(text: t) } else { ThinkingDots().padding(.vertical, 6) }
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 0) {
                                Color.clear.frame(height: 0).id("top")
                                MarkdownText(text: a.text, size: 17)
                                    .foregroundStyle(a.isError ? Color.red.opacity(0.9) : Color(white: 0.92))
                                    .padding(.trailing, 36)
                                Color.clear.frame(height: 1).id("end")
                            }
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { textHeight = $0 }
                        }
                        .frame(height: min(max(textHeight, 20), 380))
                        // follow the stream while it is being written, then jump back to the start to read it
                        .onChange(of: a.text) { if model.busy { proxy.scrollTo("end", anchor: .bottom) } }
                        .onChange(of: model.busy) { _, b in if !b { proxy.scrollTo("top", anchor: .top) } }
                    }
                    if let t = model.currentTool { ToolLine(text: t) }
                    if !model.busy {
                        HStack(spacing: 8) {
                            if let st = a.stats { StatsLine(stats: st) }
                            Spacer(minLength: 8)
                            if !a.isError, let app = model.contextAppName {
                                QuickAction(symbol: "arrow.uturn.left", title: tr("Paste into \(app)", "Tempel ke \(app)")) {
                                    model.pasteIntoPreviousApp()
                                }
                            }
                            QuickAction(symbol: "arrow.up.left.and.arrow.down.right", title: tr("Open in chat", "Buka di chat")) {
                                model.expanded = true
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Theme.inner))
            .overlay(alignment: .topTrailing) {
                if !a.text.isEmpty && !model.busy {
                    CircleButton(symbol: "doc.on.doc.fill", size: 34, tint: .blue, help: tr("Copy answer", "Salin jawaban")) { model.copyLast() }
                        .padding(14)
                }
            }
        }
    }
}

// MARK: - Expanded mode (full chat)

struct ExpandedView: View {
    @ObservedObject var model: ChatModel
    var onClose: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Shell(busy: model.busy || model.speech.listening) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    CircleButton(symbol: "xmark", size: 36, help: tr("Close (Esc)", "Tutup (Esc)"), action: onClose)
                    CircleButton(symbol: "clock.arrow.circlepath", size: 36, tint: model.showHistory ? Theme.accent : .white,
                                 help: tr("Chat history (⌘Y)", "Riwayat chat (⌘Y)")) {
                        withAnimation(.spring(duration: 0.3)) { model.showHistory.toggle() }
                    }
                    Spacer()
                    HStack(spacing: 7) {
                        Image(systemName: "sparkle").foregroundStyle(Theme.accent)
                        Text("Claude").font(.system(size: 15, weight: .semibold))
                        ModelMenu(model: model)
                        PermModeMenu(model: model)
                    }
                    Spacer()
                    CircleButton(symbol: "terminal", size: 36, help: tr("Continue in Terminal", "Lanjutkan di Terminal")) { model.openInTerminal() }
                    CircleButton(symbol: "square.and.pencil", size: 36, help: tr("New chat (⌘N)", "Chat baru (⌘N)")) { model.newChat() }
                    CircleButton(symbol: "arrow.down.right.and.arrow.up.left", size: 36, help: tr("Collapse (⌘E)", "Perkecil (⌘E)")) {
                        model.expanded = false
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 14)

                Divider().overlay(Color.white.opacity(0.06))

                HStack(spacing: 0) {
                if model.showHistory {
                    HistoryList(model: model)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    Divider().overlay(Color.white.opacity(0.06))
                }
                VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            if model.messages.isEmpty {
                                VStack(spacing: 10) {
                                    Image(systemName: "sparkle").font(.system(size: 34)).foregroundStyle(Theme.accent)
                                    Text(tr("What would you like to ask?", "Mau tanya apa?")).font(.title3).foregroundStyle(Theme.dim)
                                }
                                .frame(maxWidth: .infinity).padding(.top, 160)
                            }
                            ForEach(model.messages) { m in bubble(m).id(m.id) }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .padding(22)
                    }
                    .onChange(of: model.messages) { withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
                    .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                }

                if let p = model.preview {
                    CalcCard(result: p, big: 34).padding(.horizontal, 18).padding(.top, 10)
                }
                if let req = model.permissions.first {
                    PermissionCard(model: model, req: req).padding(.horizontal, 18).padding(.top, 10)
                }
                if let e = model.speech.error {
                    Text(e).font(.system(size: 12)).foregroundStyle(.orange).padding(.horizontal, 18).padding(.top, 8)
                }
                SelectionChip(model: model).padding(.horizontal, 18).padding(.top, 8)
                AttachmentStrip(model: model).padding(.horizontal, 18)
                HStack(spacing: 12) {
                    CircleButton(symbol: "plus", help: tr("New chat (⌘N)", "Chat baru (⌘N)")) { model.newChat() }
                    InputPill(model: model, focused: $focused)
                }
                .padding(18)
                }
                }
            }
        }
        .onAppear { focused = true }
        .onChange(of: model.focusTick) { focused = true }
    }

    @ViewBuilder private func bubble(_ m: ChatMessage) -> some View {
        if m.role == .user {
            HStack {
                Spacer(minLength: 80)
                VStack(alignment: .trailing, spacing: 6) {
                    if let c = m.context {
                        Label(c, systemImage: "text.quote").font(.system(size: 11)).foregroundStyle(Theme.dim)
                    }
                    if !m.images.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(Array(m.images.enumerated()), id: \.offset) { _, img in
                                Image(nsImage: img).resizable().scaledToFill()
                                    .frame(width: 120, height: 90)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                        }
                    }
                    if !m.text.isEmpty {
                        Text(m.text).font(.system(size: 15)).textSelection(.enabled)
                            .padding(.horizontal, 16).padding(.vertical, 11)
                            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.white.opacity(0.12)))
                    }
                }
            }
        } else if let c = m.calc {
            CalcCard(result: c, big: 34)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if !m.tools.isEmpty {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(m.tools.enumerated()), id: \.offset) { _, t in
                                Text(t).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.dim).lineLimit(1)
                            }
                        }
                    } label: {
                        Text(tr("\(m.tools.count) tools used", "\(m.tools.count) tool dipakai")).font(.system(size: 12)).foregroundStyle(Theme.dim)
                    }
                }
                if m.text.isEmpty {
                    if let t = model.currentTool, m.id == model.messages.last?.id { ToolLine(text: t) } else { ThinkingDots() }
                } else {
                    MarkdownText(text: m.text, size: 15)
                        .foregroundStyle(m.isError ? Color.red.opacity(0.9) : Color(white: 0.92))
                    if let t = model.currentTool, m.id == model.messages.last?.id, model.busy { ToolLine(text: t) }
                    if let st = m.stats { StatsLine(stats: st).padding(.top, 2) }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.inner))
        }
    }
}

// MARK: - Panel dragging

/// Drag the panel using the screen mouse position (stable even while the window moves).
@MainActor
enum WindowMover {
    static weak var panel: NSWindow?
    static var startMouse: NSPoint?
    static var startOrigin: NSPoint = .zero
    static var onEnd: (() -> Void)?

    static func changed() {
        guard let w = panel else { return }
        let m = NSEvent.mouseLocation
        if startMouse == nil { startMouse = m; startOrigin = w.frame.origin }
        guard let s = startMouse else { return }
        w.setFrameOrigin(NSPoint(x: startOrigin.x + m.x - s.x, y: startOrigin.y + m.y - s.y))
    }
    static func ended() { startMouse = nil; onEnd?() }
}

extension View {
    func windowDrag() -> some View {
        gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { _ in WindowMover.changed() }
            .onEnded { _ in WindowMover.ended() })
    }
}
