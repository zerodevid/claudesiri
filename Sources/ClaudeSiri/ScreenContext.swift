import AppKit
import ApplicationServices

/// Konteks layar: app yang sedang aktif, teks yang dipilih di sana, dan screenshot jendelanya.
@MainActor
enum ScreenContext {
    struct Selected: Equatable {
        let app: String
        let text: String
    }

    /// App di depan selain ClaudeSiri (panel kita non-aktif, jadi app user tetap frontmost).
    static func frontApp() -> NSRunningApplication? {
        let me = ProcessInfo.processInfo.processIdentifier
        if let f = NSWorkspace.shared.frontmostApplication, f.processIdentifier != me { return f }
        return nil
    }

    static var axTrusted: Bool { AXIsProcessTrusted() }

    static func requestAX() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Teks yang sedang diblok di app depan (butuh izin Aksesibilitas).
    static func selectedText(in app: NSRunningApplication) -> String? {
        guard axTrusted else { return nil }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let f = focused else { return nil }
        var sel: CFTypeRef?
        guard AXUIElementCopyAttributeValue(f as! AXUIElement, kAXSelectedTextAttribute as CFString, &sel) == .success,
              let s = sel as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : String(t.prefix(20_000))
    }

    /// Screenshot jendela paling depan milik app (butuh izin Screen Recording; macOS menanyakan sekali).
    static func captureWindow(of app: NSRunningApplication) -> NSImage? {
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            return nil
        }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let win = list.first(where: {
                  ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier
                      && ($0[kCGWindowLayer as String] as? Int) == 0
              }),
              let wid = win[kCGWindowNumber as String] as? Int else { return nil }
        let path = NSTemporaryDirectory() + "claudesiri-window-\(wid).png"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l\(wid)", path]
        try? p.run()
        p.waitUntilExit()
        defer { try? FileManager.default.removeItem(atPath: path) }
        return NSImage(contentsOfFile: path)
    }
}
