@preconcurrency import AVFoundation
import WhisperKit
import os.log

/// Speech-to-text service powered by WhisperKit (on-device Whisper model).
/// Observable state lives on @MainActor; all audio/transcription work is delegated
/// to a non-isolated WhisperEngine to avoid Swift 6 actor isolation crashes.
@MainActor
@Observable
final class SpeechRecognitionService {
    // MARK: - Types

    enum State: Equatable {
        case idle
        case loading       // Model is loading
        case recording
        case error(String)
    }

    // MARK: - Observable State

    var state: State = .idle
    var liveText = ""
    /// Whether the WhisperKit model has been loaded and is ready.
    var isModelReady = false

    // MARK: - Private

    @ObservationIgnored private var engine: WhisperEngine?
    @ObservationIgnored private var pollingTask: Task<Void, Never>?

    private let logger = Logger(subsystem: "com.clawtower.mobile", category: "SpeechRecognition")

    // MARK: - Model Loading

    /// Pre-load the WhisperKit model at app launch.
    /// Call this once from app startup to avoid delays when user first taps mic.
    func loadModel() async {
        guard !isModelReady else { return }
        state = .loading
        logger.info("Loading WhisperKit model...")

        let newEngine = WhisperEngine()
        let success = await newEngine.loadModel()

        if success {
            engine = newEngine
            isModelReady = true
            state = .idle
            logger.info("WhisperKit model loaded successfully")
        } else {
            state = .error(String(localized: "voice.unavailable"))
            logger.error("Failed to load WhisperKit model")
        }
    }

    // MARK: - Permission

    func requestPermissions() async -> Bool {
        await WhisperEngine.requestMicPermission()
    }

    // MARK: - Recording Control

    func startRecording() {
        guard state == .idle, isModelReady, let engine else { return }

        liveText = ""

        let started = engine.startCapture()
        guard started else {
            state = .error(String(localized: "voice.recording_failed"))
            return
        }

        state = .recording
        logger.info("Recording started with WhisperKit")

        // Poll engine for transcription results
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self else { break }
                guard self.state == .recording else { break }
                guard let engine = self.engine else { break }

                let text = engine.currentText()
                if !text.isEmpty {
                    self.liveText = text
                }
            }
        }
    }

    @discardableResult
    func stopRecording() -> String {
        guard state == .recording else { return liveText }

        pollingTask?.cancel()
        pollingTask = nil

        // Drain final text
        if let engine {
            let finalText = engine.currentText()
            if !finalText.isEmpty {
                liveText = finalText
            }
            engine.stopCapture()
        }

        state = .idle
        logger.info("Recording stopped, transcribed \(self.liveText.count) chars")
        return liveText
    }

    func cancelRecording() {
        pollingTask?.cancel()
        pollingTask = nil
        engine?.stopCapture()
        liveText = ""
        state = .idle
        logger.info("Recording cancelled")
    }
}

// MARK: - WhisperEngine (non-isolated, runs audio capture + WhisperKit transcription)

/// Performs all audio capture and WhisperKit transcription work.
/// This class is intentionally NOT @MainActor — it can be safely used from
/// closures running on audio threads. The WhisperKit transcription runs
/// on a background task, results are polled by the MainActor service.
private final class WhisperEngine: @unchecked Sendable {
    private let lock = NSLock()

    // Protected by lock
    private var _audioBuffer: [Float] = []
    private var _currentText = ""
    private var _isTranscribing = false

    // Audio capture (managed from start/stop which are called from MainActor)
    private var audioEngine: AVAudioEngine?
    private var whisperKit: WhisperKit?
    private var transcriptionTask: Task<Void, Never>?

    private let logger = Logger(subsystem: "com.clawtower.mobile", category: "WhisperEngine")

    /// Load the WhisperKit model from the app bundle.
    func loadModel() async -> Bool {
        // All model + tokenizer files are at the root of the app bundle
        // (xcodegen flattens the WhisperKitModels folder resource).
        guard let modelPath = Bundle.main.resourcePath else {
            logger.error("Bundle resource path not found")
            return false
        }

        let modelURL = URL(fileURLWithPath: modelPath)

        do {
            let config = WhisperKitConfig(
                modelFolder: modelPath,
                tokenizerFolder: modelURL,
                computeOptions: ModelComputeOptions(
                    audioEncoderCompute: .cpuAndNeuralEngine,
                    textDecoderCompute: .cpuAndNeuralEngine
                ),
                verbose: false,
                logLevel: .none,
                prewarm: false,
                load: true,
                download: false
            )
            whisperKit = try await WhisperKit(config)
            logger.info("WhisperKit initialized with base model")
            return true
        } catch {
            logger.error("WhisperKit init failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Read current transcription text (thread-safe).
    func currentText() -> String {
        lock.lock()
        defer { lock.unlock() }
        return _currentText
    }

    // MARK: - Lock Helpers (synchronous, safe to call from any context)

    /// Try to claim the transcription lock. Returns the audio buffer if successful, nil if already transcribing.
    private func claimTranscription() -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        guard !_isTranscribing else { return nil }
        _isTranscribing = true
        return _audioBuffer
    }

    /// Release transcription lock and optionally update the current text.
    private func finishTranscription(text: String?) {
        lock.lock()
        if let text, !text.isEmpty {
            _currentText = text
        }
        _isTranscribing = false
        lock.unlock()
    }

    /// Start audio capture and begin periodic transcription.
    func startCapture() -> Bool {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            logger.error("Audio session setup failed: \(error.localizedDescription)")
            return false
        }

        lock.lock()
        _audioBuffer = []
        _currentText = ""
        _isTranscribing = false
        lock.unlock()

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)

        // We need 16kHz mono Float32 for WhisperKit
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            logger.error("Failed to create target audio format")
            return false
        }

        guard let converter = AVAudioConverter(from: nativeFormat, to: targetFormat) else {
            logger.error("Failed to create audio converter")
            return false
        }

        // Audio tap — runs on audio render thread.
        // Only captures converter, targetFormat, and self (WhisperEngine, @unchecked Sendable).
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
            guard let self else { return }

            let frameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * targetFormat.sampleRate / nativeFormat.sampleRate
            )
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else { return }

            var error: NSError?
            let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, error == nil else { return }

            if let channelData = convertedBuffer.floatChannelData?[0] {
                let samples = Array(UnsafeBufferPointer(start: channelData, count: Int(convertedBuffer.frameLength)))
                self.lock.lock()
                self._audioBuffer.append(contentsOf: samples)
                self.lock.unlock()
            }
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            logger.error("Audio engine start failed: \(error.localizedDescription)")
            return false
        }
        audioEngine = engine

        // Start periodic transcription loop
        transcriptionTask = Task { [weak self] in
            // Wait a bit before first transcription to accumulate audio
            try? await Task.sleep(for: .seconds(1))

            while !Task.isCancelled {
                guard let self else { break }
                await self.transcribeCurrentBuffer()
                try? await Task.sleep(for: .seconds(1))
            }
        }

        return true
    }

    /// Stop audio capture and transcription.
    func stopCapture() {
        transcriptionTask?.cancel()
        transcriptionTask = nil

        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Transcribe the accumulated audio buffer.
    private func transcribeCurrentBuffer() async {
        // Try to claim the transcription slot (synchronous, no lock in async context)
        guard let audioSamples = claimTranscription() else { return }

        guard !audioSamples.isEmpty, let whisperKit else {
            finishTranscription(text: nil)
            return
        }

        do {
            let options = DecodingOptions(
                language: "zh",
                temperatureFallbackCount: 0,
                sampleLength: 224,
                usePrefillPrompt: true,
                skipSpecialTokens: true,
                withoutTimestamps: true
            )

            let results = try await whisperKit.transcribe(
                audioArray: audioSamples,
                decodeOptions: options
            )

            let text = results.map { $0.text }.joined(separator: "").trimmingCharacters(in: .whitespacesAndNewlines)
            finishTranscription(text: text)
        } catch {
            logger.error("Transcription error: \(error.localizedDescription)")
            finishTranscription(text: nil)
        }
    }

    // MARK: - Static Permission Helpers

    static func requestMicPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
