// Copyright 2026 ICOA Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation
import AVFoundation
import Shared

/// Captures caller audio, segments utterances with an energy VAD, and transcribes them
/// with a local whisper.cpp server (multilingual, automatic language detection).
public final class WhisperCapture: @unchecked Sendable {
    private let sessionManager: AudioSessionManager
    private let serverURL: URL
    private let logger = PhoneBTLogger(category: .audio)
    private let queue = DispatchQueue(label: "phonebt.whisper.vad")
    private let session: URLSession

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false
    )!
    private var converter: AVAudioConverter?
    private var isCapturing = false
    private var handlerID: UUID?

    // VAD state (accessed on `queue`)
    private var segment: [Float] = []
    private var preRoll: [Float] = []
    private var inSpeech = false
    private var speechFrames = 0
    private var silenceDuration: Double = 0
    private var noiseFloor: Float = 0.005

    // VAD tuning
    private let minThreshold: Float = 0.01
    private let silenceToEnd: Double = 0.8
    private let maxSegment: Double = 15
    private let minSegment: Double = 0.4
    /// Audio kept before speech is detected, so the first syllable isn't cut off
    private let preRollDuration: Double = 0.6

    // Activity (read from other threads)
    private let activityLock = NSLock()
    private var lastVoice = Date.distantPast
    private var segmentOpen = false
    private var pendingTranscriptions = 0

    /// Called with each transcribed utterance and its detected language (ISO 639-1)
    public var onTranscription: ((String, String?) -> Void)?

    /// When true, incoming audio is ignored (e.g. while our own TTS is playing)
    public var isMuted = false

    /// The other party is talking, or what they just said is still being transcribed
    public var isCallerBusy: Bool {
        activityLock.lock(); defer { activityLock.unlock() }
        return segmentOpen || pendingTranscriptions > 0 || Date().timeIntervalSince(lastVoice) < 1.0
    }

    private func setActivity(voice: Bool? = nil, segmentOpen open: Bool? = nil, pendingDelta: Int = 0) {
        activityLock.lock()
        if voice == true { lastVoice = Date() }
        if let open { segmentOpen = open }
        pendingTranscriptions += pendingDelta
        activityLock.unlock()
    }

    /// Language spoken in the call (ISO 639-1), or nil for automatic detection
    public var language: String? {
        get { languageLock.lock(); defer { languageLock.unlock() }; return fixedLanguage }
        set { languageLock.lock(); fixedLanguage = newValue; languageLock.unlock() }
    }
    private var fixedLanguage: String?
    private let languageLock = NSLock()

    public init(sessionManager: AudioSessionManager, serverURL: URL) {
        self.sessionManager = sessionManager
        self.serverURL = serverURL
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        self.session = URLSession(configuration: config)
    }

    public func start() throws {
        guard !isCapturing else { return }
        isCapturing = true

        let inputFormat = sessionManager.inputFormat
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        handlerID = sessionManager.addInputHandler { [weak self] buffer in
            guard let self, let samples = self.resample(buffer) else { return }
            self.queue.async { self.process(samples) }
        }
        logger.info("Whisper capture started (\(inputFormat.sampleRate) Hz → 16 kHz)")
    }

    public func stop() {
        guard isCapturing else { return }
        isCapturing = false
        if let handlerID { sessionManager.removeInputHandler(handlerID) }
        handlerID = nil
        queue.async { [weak self] in
            self?.resetSegment()
        }
        logger.info("Whisper capture stopped")
    }

    // MARK: - Resampling

    private func resample(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let converter else { return nil }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

        var provided = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if provided {
                status.pointee = .noDataNow
                return nil
            }
            provided = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }

    // MARK: - VAD (runs on `queue`)

    private func process(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        if isMuted {
            if inSpeech { resetSegment() }
            return
        }

        let duration = Double(samples.count) / targetFormat.sampleRate
        let rms = Self.rms(samples)
        let threshold = max(minThreshold, noiseFloor * 3)
        let isVoice = rms > threshold
        if isVoice { setActivity(voice: true) }

        if !inSpeech {
            // Track background noise slowly while idle
            noiseFloor = noiseFloor * 0.95 + rms * 0.05
            preRoll.append(contentsOf: samples)
            let maxPreRoll = Int(preRollDuration * targetFormat.sampleRate)
            if preRoll.count > maxPreRoll { preRoll.removeFirst(preRoll.count - maxPreRoll) }

            speechFrames = isVoice ? speechFrames + 1 : 0
            if speechFrames >= 3 {
                inSpeech = true
                setActivity(segmentOpen: true)
                silenceDuration = 0
                segment = preRoll
                preRoll.removeAll()
            }
            return
        }

        segment.append(contentsOf: samples)
        silenceDuration = isVoice ? 0 : silenceDuration + duration
        let segmentDuration = Double(segment.count) / targetFormat.sampleRate

        if silenceDuration >= silenceToEnd || segmentDuration >= maxSegment {
            let utterance = segment
            resetSegment()
            if segmentDuration - silenceDuration >= minSegment {
                transcribe(utterance)
            }
        }
    }

    private func resetSegment() {
        setActivity(segmentOpen: false)
        segment.removeAll()
        preRoll.removeAll()
        inSpeech = false
        speechFrames = 0
        silenceDuration = 0
    }

    static func rms(_ samples: [Float]) -> Float {
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }

    // MARK: - Transcription

    private func transcribe(_ samples: [Float]) {
        let wav = Self.wavData(samples: samples, sampleRate: Int(targetFormat.sampleRate))
        let url = serverURL.appendingPathComponent("inference")
        let session = self.session
        let fixed = self.language

        setActivity(pendingDelta: 1)
        Task { [weak self] in
            defer { self?.setActivity(pendingDelta: -1) }
            do {
                let (text, detected) = try await Self.requestTranscription(wav: wav, url: url, session: session, language: fixed)
                let language = fixed ?? detected
                guard let self else { return }
                guard let cleaned = Self.cleanTranscription(text) else { return }
                self.logger.info("Whisper [\(language ?? "?")]: \(cleaned)")
                self.onTranscription?(cleaned, language)
            } catch {
                self?.logger.error("Whisper transcription failed: \(error)")
            }
        }
    }

    private static func requestTranscription(wav: Data, url: URL, session: URLSession, language: String?) async throws -> (String, String?) {
        let boundary = "phonebt-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n".data(using: .utf8)!)
        field("response_format", "verbose_json")
        field("language", language ?? "auto")
        field("temperature", "0.0")
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw WhisperError.serverError(String(data: data, encoding: .utf8) ?? "")
        }
        return try parseResponse(data)
    }

    static func parseResponse(_ data: Data) throws -> (String, String?) {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WhisperError.invalidResponse
        }
        if let error = json["error"] as? String { throw WhisperError.serverError(error) }
        let text = (json["text"] as? String ?? "")
            .replacingOccurrences(of: #"\s*\n\s*"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, (json["language"] as? String).map(languageCode))
    }

    /// whisper.cpp reports full names ("french") — map the common ones to ISO codes
    static func languageCode(_ name: String) -> String {
        let map = [
            "arabic": "ar", "english": "en", "french": "fr", "german": "de", "hebrew": "he",
            "italian": "it", "portuguese": "pt", "russian": "ru", "spanish": "es",
        ]
        let lower = name.lowercased()
        return map[lower] ?? lower
    }

    /// Drop empty output and Whisper's classic hallucinations on silence/noise
    static func cleanTranscription(_ text: String) -> String? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Remove bracketed annotations like [Music] or (applause)
        t = t.replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*\)|\*[^*]*\*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2 else { return nil }

        let hallucinations = [
            "sous-titrage", "sous-titres réalisés", "merci d'avoir regardé",
            "thank you for watching", "thanks for watching", "subtitles by",
            "תודה רבה לצפייה", "תרגום:",
        ]
        let lower = t.lowercased()
        if hallucinations.contains(where: { lower.contains($0) }) { return nil }
        return t
    }

    static func wavData(samples: [Float], sampleRate: Int) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let byteCount = samples.count * 2
        data.append("RIFF".data(using: .ascii)!)
        append(UInt32(36 + byteCount))
        data.append("WAVEfmt ".data(using: .ascii)!)
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2))
        append(UInt16(2)); append(UInt16(16))
        data.append("data".data(using: .ascii)!)
        append(UInt32(byteCount))
        for s in samples {
            append(Int16(max(-1, min(1, s)) * Float(Int16.max)))
        }
        return data
    }
}

public enum WhisperError: Error, LocalizedError {
    case invalidResponse
    case serverError(String)
    case serverNotFound
    case modelNotFound(String)
    case startTimeout

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return L("Invalid Whisper response", "Réponse Whisper invalide")
        case .serverError(let msg): return "Erreur serveur Whisper : \(msg)"
        case .serverNotFound: return L("whisper-server not found — install it with `brew install whisper-cpp`", "whisper-server introuvable — installe-le avec `brew install whisper-cpp`")
        case .modelNotFound(let path): return L("Whisper model not found: ", "Modèle Whisper introuvable : ") + path
        case .startTimeout: return L("whisper-server didn't start in time", "whisper-server n'a pas démarré à temps")
        }
    }
}

/// Starts and owns a local whisper-server process (auto language detection)
public final class WhisperServer: @unchecked Sendable {
    public let url: URL
    private let modelPath: String
    private var process: Process?
    private let logger = PhoneBTLogger(category: .audio)

    public init(port: Int, modelPath: String) {
        self.url = URL(string: "http://127.0.0.1:\(port)")!
        self.modelPath = modelPath
    }

    public func isRunning() async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        return (try? await URLSession.shared.data(for: request)) != nil
    }

    /// Start whisper-server unless one already answers on the port
    public func ensureRunning() async throws {
        if await isRunning() { return }

        let candidates = ["/opt/homebrew/bin/whisper-server", "/usr/local/bin/whisper-server"]
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw WhisperError.serverNotFound
        }
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw WhisperError.modelNotFound(modelPath)
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = [
            "-m", modelPath,
            "-l", "auto",
            "--host", "127.0.0.1",
            "--port", String(url.port ?? 8178),
            "-t", "4",
            // Encode 16 s instead of Whisper's fixed 30 s window: segments are at most 15 s
            // (+ pre-roll), and transcription with language detection gets ~2x faster
            "-ac", "800",
        ]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        process = p
        logger.info("whisper-server started (pid \(p.processIdentifier))")

        for _ in 0..<60 {
            try await Task.sleep(nanoseconds: 500_000_000)
            if await isRunning() { return }
        }
        throw WhisperError.startTimeout
    }

    public func stop() {
        process?.terminate()
        process = nil
    }
}
