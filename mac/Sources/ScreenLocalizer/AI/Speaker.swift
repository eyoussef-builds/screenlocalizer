import AVFoundation
import Combine

/// Reads results aloud with either the built-in macOS voices or OpenAI text-to-speech.
final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    static let shared = Speaker()

    @Published private(set) var isSpeaking = false
    @Published private(set) var isLoading = false
    @Published var lastError: String?

    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var queue: [String] = []
    private var task: Task<Void, Never>?

    static let openAIVoices = ["alloy", "ash", "ballad", "coral", "echo", "fable", "nova", "onyx", "sage", "shimmer"]

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func toggle(_ text: String) {
        if isSpeaking || isLoading { stop() } else { speak(text) }
    }

    func speak(_ text: String) {
        stop()
        let clean = Speaker.plainText(text)
        guard !clean.isEmpty else { return }
        lastError = nil
        let settings = AppSettings.shared
        if settings.ttsEngine == .openai, let config = settings.speechConfig {
            speakWithOpenAI(clean, config: config, voice: settings.openAIVoice)
        } else {
            speakWithSystem(clean, language: settings.targetLanguage, voiceID: settings.systemVoiceID)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        queue = []
        player?.stop()
        player = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        isSpeaking = false
        isLoading = false
    }

    // MARK: System voice

    static func voices(for language: String) -> [AVSpeechSynthesisVoice] {
        let code = Languages.speechCode(language)
        let prefix = String(code.prefix(2))
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(prefix) }
            .sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
    }

    private func speakWithSystem(_ text: String, language: String, voiceID: String) {
        let utterance = AVSpeechUtterance(string: text)
        if !voiceID.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: voiceID) {
            utterance.voice = voice
        } else {
            utterance.voice = Speaker.voices(for: language).first ?? AVSpeechSynthesisVoice(language: Languages.speechCode(language))
        }
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.isSpeaking = false }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.isSpeaking = false }
    }

    // MARK: OpenAI voice

    private func speakWithOpenAI(_ text: String, config: LLMConfig, voice: String) {
        queue = Speaker.chunks(text, limit: 3500)
        isLoading = true
        playNext(config: config, voice: voice)
    }

    private func playNext(config: LLMConfig, voice: String) {
        guard !queue.isEmpty else {
            isSpeaking = false
            isLoading = false
            return
        }
        let chunk = queue.removeFirst()
        task = Task { @MainActor in
            do {
                let data = try await LLMClient.speech(config: config, text: chunk, voice: voice)
                try Task.checkCancellation()
                let player = try AVAudioPlayer(data: data)
                player.delegate = self
                self.player = player
                self.isLoading = false
                self.isSpeaking = true
                player.play()
            } catch is CancellationError {
            } catch {
                self.lastError = error.localizedDescription
                self.isLoading = false
                self.isSpeaking = false
            }
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            guard let config = AppSettings.shared.speechConfig else { self.stop(); return }
            if self.queue.isEmpty { self.isSpeaking = false } else { self.playNext(config: config, voice: AppSettings.shared.openAIVoice) }
        }
    }

    // MARK: Helpers

    static func plainText(_ markdown: String) -> String {
        var text = markdown
        for token in ["**", "__", "`", "###", "##", "#"] { text = text.replacingOccurrences(of: token, with: "") }
        let lines = text.components(separatedBy: "\n").map { line -> String in
            var l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("- ") || l.hasPrefix("* ") || l.hasPrefix("• ") { l = String(l.dropFirst(2)) }
            return l
        }
        return lines.joined(separator: "\n").trimmed
    }

    static func chunks(_ text: String, limit: Int) -> [String] {
        var result: [String] = []
        var current = ""
        for paragraph in text.components(separatedBy: "\n") {
            if current.count + paragraph.count + 1 > limit, !current.isEmpty {
                result.append(current)
                current = ""
            }
            if paragraph.count > limit {
                var rest = Substring(paragraph)
                while !rest.isEmpty {
                    result.append(String(rest.prefix(limit)))
                    rest = rest.dropFirst(limit)
                }
            } else {
                current += (current.isEmpty ? "" : "\n") + paragraph
            }
        }
        if !current.trimmed.isEmpty { result.append(current) }
        return result
    }
}
