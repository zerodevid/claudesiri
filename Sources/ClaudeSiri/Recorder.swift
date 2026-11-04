import AppKit
import ScreenCaptureKit

/// Docs tool: record/screenshot the main display using ClaudeSiri's own Screen Recording permission.
///   open -n ClaudeSiri.app --args --record <file.mov> [max-seconds]   (stops when <file.mov>.stop is created)
///   open -n ClaudeSiri.app --args --shot <file.png>
///   add --display N for another display (0 = main display)
@available(macOS 15.0, *)
final class ScreenRecorder: NSObject, SCRecordingOutputDelegate {
    private var stream: SCStream?
    private var done: CheckedContinuation<Void, Never>?

    static func log(_ s: String) {
        FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    }

    private static func mainDisplay() async throws -> (SCDisplay, Int, Int) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let a = CommandLine.arguments
        let want = a.firstIndex(of: "--display").flatMap { $0 + 1 < a.count ? Int(a[$0 + 1]) : nil }
        let sorted = content.displays.sorted { ($0.displayID == CGMainDisplayID() ? 0 : 1) < ($1.displayID == CGMainDisplayID() ? 0 : 1) }
        guard let d = want.flatMap({ $0 < sorted.count ? sorted[$0] : nil }) ?? sorted.first
        else { throw NSError(domain: "rec", code: 1, userInfo: [NSLocalizedDescriptionKey: "tidak ada layar"]) }
        let mode = CGDisplayCopyDisplayMode(d.displayID)
        return (d, mode?.pixelWidth ?? d.width, mode?.pixelHeight ?? d.height)
    }

    static func shot(to path: String) async throws {
        let (d, w, h) = try await mainDisplay()
        let cfg = SCStreamConfiguration()
        cfg.width = w; cfg.height = h; cfg.showsCursor = true
        let img = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: d, excludingWindows: []),
                                                             configuration: cfg)
        let rep = NSBitmapImageRep(cgImage: img)
        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    func record(to path: String, maxSeconds: Double) async throws {
        let (d, w, h) = try await Self.mainDisplay()
        let cfg = SCStreamConfiguration()
        cfg.width = w; cfg.height = h
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        cfg.showsCursor = true
        cfg.queueDepth = 8
        let s = SCStream(filter: SCContentFilter(display: d, excludingWindows: []), configuration: cfg, delegate: nil)
        let rc = SCRecordingOutputConfiguration()
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.removeItem(at: url)
        rc.outputURL = url
        rc.outputFileType = .mov
        rc.videoCodecType = .h264
        try s.addRecordingOutput(SCRecordingOutput(configuration: rc, delegate: self))
        try await s.startCapture()
        stream = s
        Self.log("rekam \(w)x\(h) → \(path)")
        let stop = path + ".stop"
        try? FileManager.default.removeItem(atPath: stop)
        let start = Date()
        while Date().timeIntervalSince(start) < maxSeconds, !FileManager.default.fileExists(atPath: stop) {
            try await Task.sleep(for: .milliseconds(200))
        }
        await withCheckedContinuation { c in
            done = c
            Task { try? await s.stopCapture() }
        }
        Self.log("selesai \(String(format: "%.1f", Date().timeIntervalSince(start))) dtk")
    }

    func recordingOutputDidFinishRecording(_ o: SCRecordingOutput) { done?.resume(); done = nil }
    func recordingOutput(_ o: SCRecordingOutput, didFailWithError e: Error) {
        Self.log("gagal: \(e.localizedDescription)"); done?.resume(); done = nil
    }

    /// Called from main before AppDelegate is created. Returns true when record/shot mode is active.
    static func runIfRequested() -> Bool {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--shot"), i + 1 < a.count {
            Task {
                do { try await shot(to: a[i + 1]); exit(0) } catch { log("gagal: \(error.localizedDescription)"); exit(1) }
            }
            return true
        }
        if let i = a.firstIndex(of: "--record"), i + 1 < a.count {
            let secs = i + 2 < a.count ? Double(a[i + 2]) ?? 120 : 120
            let r = ScreenRecorder()
            Task {
                do { try await r.record(to: a[i + 1], maxSeconds: secs); exit(0) }
                catch { log("gagal: \(error.localizedDescription)"); exit(1) }
            }
            return true
        }
        return false
    }
}
