import Foundation
import Speech
import AVFoundation

/// Push-to-talk speech-to-text. On-device where available; fills the
/// command bar. Currently dictation only — no voice planner, no autonomous actions.
@MainActor
final class VoiceInput: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var transcript = ""
    @Published private(set) var unavailableReason: String?

    private let recognizer = SFSpeechRecognizer()
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Begin recording after ensuring mic + speech permission.
    func start() {
        guard !isRecording else { return }
        ensureAuthorized { [weak self] ok, reason in
            guard let self else { return }
            guard ok else { self.unavailableReason = reason; return }
            self.beginSession()
        }
    }

    func stop() {
        guard isRecording else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil
        isRecording = false
    }

    // MARK: Authorization

    private func ensureAuthorized(_ completion: @escaping (Bool, String?) -> Void) {
        // Ask for speech first; only prompt for the mic once speech is granted, so a
        // user who declines speech isn't also pestered for microphone access.
        SFSpeechRecognizer.requestAuthorization { speechStatus in
            guard speechStatus == .authorized else {
                DispatchQueue.main.async {
                    completion(false, "Speech recognition not permitted — enable it in System Settings › Privacy.")
                }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { micGranted in
                DispatchQueue.main.async {
                    guard micGranted else {
                        completion(false, "Microphone access denied — enable it in System Settings › Privacy.")
                        return
                    }
                    completion(true, nil)
                }
            }
        }
    }

    // MARK: Session

    private func beginSession() {
        guard let recognizer, recognizer.isAvailable else {
            unavailableReason = "Speech recognition is unavailable right now."
            return
        }
        transcript = ""

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            req.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            unavailableReason = "Couldn't start the microphone."
            input.removeTap(onBus: 0)
            return
        }
        isRecording = true

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result { self.transcript = result.bestTranscription.formattedString }
                if error != nil || (result?.isFinal ?? false) { self.stop() }
            }
        }
    }
}
