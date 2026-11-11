import AVFoundation
import ScreenCaptureKit
import Speech

enum Speaker: String, CaseIterable { case me = "Me", them = "Them" }

struct BSError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

// MARK: - Ears: Granola-style capture, no bot joins the call.
// System audio is the other person; the microphone is you. Two participants means two streams and no diarization.

@available(macOS 26.0, *)
final class CallAudio: NSObject, SCStreamOutput, SCStreamDelegate {
    /// Called on `queue` (serial) for every chunk of audio.
    var onBuffer: ((Speaker, AVAudioPCMBuffer) -> Void)?
    var onStop: ((Error) -> Void)?
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "bs.audio")

    func start() async throws {
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) }
        catch { throw BSError("Allow Screen Recording for BS Detector in System Settings, then restart it.") }
        guard let display = content.displays.first else { throw BSError("No display to capture.") }
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true   // don't transcribe our own buzzer
        config.captureMicrophone = true
        config.sampleRate = 48_000
        config.channelCount = 1
        config.width = 2; config.height = 2         // audio only; keep the video side as cheap as possible
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let stream = SCStream(filter: SCContentFilter(display: display, excludingApplications: [], exceptingWindows: []), configuration: config, delegate: self)
        for type in [SCStreamOutputType.screen, .audio, .microphone] { try stream.addStreamOutput(self, type: type, sampleHandlerQueue: queue) }
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type != .screen, sample.isValid, let buffer = sample.pcmBuffer else { return }
        onBuffer?(type == .microphone ? .me : .them, buffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { onStop?(error) }
}

extension CMSampleBuffer {
    /// Copies the samples into an AVAudioPCMBuffer in the buffer's own format.
    var pcmBuffer: AVAudioPCMBuffer? {
        guard let desc = formatDescription else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: desc)
        let frames = AVAudioFrameCount(numSamples)
        guard frames > 0, let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        out.frameLength = frames
        return CMSampleBufferCopyPCMDataIntoAudioBufferList(self, at: 0, frameCount: Int32(frames), into: out.mutableAudioBufferList) == noErr ? out : nil
    }
}

// MARK: - Transcription: Apple's on-device SpeechAnalyzer, one per speaker.

@available(macOS 26.0, *)
final class Transcriber {
    let speaker: Speaker
    private let module: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let format: AVAudioFormat
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private var converter: AVAudioConverter?   // only touched from the audio queue
    private var reader: Task<Void, Never>?

    /// Picks an English locale and downloads the speech model once (a few hundred MB the first time).
    static func locale() async throws -> Locale {
        guard SpeechTranscriber.isAvailable else { throw BSError("On-device speech recognition isn't available on this Mac.") }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current.language.languageCode == .english ? .current : Locale(identifier: "en-US")) else {
            throw BSError("No speech model for this language.")
        }
        let probe = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [probe]) { try await install.downloadAndInstall() }
        return locale
    }

    /// `onText(text, isFinal)`: volatile results replace each other until a final one lands.
    init(_ speaker: Speaker, locale: Locale, onText: @escaping @MainActor (String, Bool) -> Void, onError: @escaping @MainActor (Error) -> Void = { _ in }) async throws {
        self.speaker = speaker
        let module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else { throw BSError("Speech model has no audio format.") }
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [module])
        try await analyzer.prepareToAnalyze(in: format)
        try await analyzer.start(inputSequence: stream)
        (self.module, self.analyzer, self.format, self.input) = (module, analyzer, format, input)
        reader = Task {
            do { for try await r in module.results { await onText(String(r.text.characters), r.isFinal) } }
            catch { await onError(error) }
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        if let converted = convert(buffer) { input.yield(AnalyzerInput(buffer: converted)) }
    }

    /// Flushes the last words, then stops.
    func finish() async {
        input.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        await reader?.value
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.primeMethod = .none   // streaming: no priming silence between chunks
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate).rounded(.up)) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, state in
            if fed { state.pointee = .noDataNow; return nil }
            fed = true; state.pointee = .haveData; return buffer
        }
        return status != .error && out.frameLength > 0 ? out : nil
    }
}
