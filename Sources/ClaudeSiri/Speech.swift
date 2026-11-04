import Foundation
import Speech
import AVFoundation

/// Pengenal suara: ketuk mic → bicara → teks masuk live ke kolom → diam 1,6 dtk → otomatis kirim.
@MainActor
final class SpeechInput: ObservableObject {
    @Published private(set) var listening = false
    @Published private(set) var level: Float = 0
    @Published var error: String?

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var onText: ((String) -> Void)?
    private var onDone: ((String) -> Void)?
    private var latest = ""

    var locale: String { UserDefaults.standard.string(forKey: "speechLocale") ?? "id-ID" }

    func toggle(onText: @escaping (String) -> Void, onDone: @escaping (String) -> Void) {
        if listening { finish(); return }
        self.onText = onText
        self.onDone = onDone
        error = nil
        SFSpeechRecognizer.requestAuthorization { status in
            AVCaptureDevice.requestAccess(for: .audio) { mic in
                DispatchQueue.main.async {
                    guard status == .authorized else { self.error = "Izin Pengenalan Ucapan belum diberikan (System Settings › Privacy)"; return }
                    guard mic else { self.error = "Izin mikrofon belum diberikan (System Settings › Privacy › Microphone)"; return }
                    self.start()
                }
            }
        }
    }

    private func start() {
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: locale)), rec.isAvailable else {
            error = "Pengenal suara \(locale) tidak tersedia"; return
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = false }
        req.addsPunctuation = true
        request = req
        latest = ""

        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            req.append(buf)
            guard let ch = buf.floatChannelData?[0] else { return }
            let n = Int(buf.frameLength)
            var sum: Float = 0
            for i in stride(from: 0, to: n, by: 4) { sum += ch[i] * ch[i] }
            let rms = sqrt(sum / Float(max(n / 4, 1)))
            DispatchQueue.main.async { self?.level = min(1, rms * 12) }
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            self.error = "Mikrofon gagal: \(error.localizedDescription)"; return
        }
        listening = true
        armSilence(after: 6)   // kalau tak bicara sama sekali, berhenti sendiri

        task = rec.recognitionTask(with: req) { [weak self] result, err in
            DispatchQueue.main.async {
                guard let self, self.listening else { return }
                if let r = result {
                    self.latest = r.bestTranscription.formattedString
                    self.onText?(self.latest)
                    self.armSilence(after: 1.6)
                    if r.isFinal { self.finish() }
                } else if err != nil {
                    self.finish()
                }
            }
        }
    }

    private func armSilence(after s: TimeInterval) {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: s, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.finish() }
        }
    }

    func finish() {
        guard listening else { return }
        listening = false
        level = 0
        silenceTimer?.invalidate()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        let t = latest.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { onDone?(t) }
    }
}
