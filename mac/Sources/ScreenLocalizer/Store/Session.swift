import Foundation
import Combine

/// One piece of source text and everything generated from it (per-mode results and follow-up chat).
@MainActor
final class Session: ObservableObject, Identifiable {
    let id: UUID
    let createdAt: Date
    let origin: SourceOrigin
    let context: SourceContext

    @Published var source: String
    @Published var mode: Mode
    @Published var outputs: [Mode: String] = [:]
    @Published var turns: [ChatTurn] = []
    @Published var isStreaming = false
    @Published var streamingMode: Mode?
    @Published var error: String?
    @Published var needsKey = false
    /// True for the paste box: the source text is typed or pasted into the panel itself.
    @Published var editingSource: Bool
    /// Bumped on every streamed chunk so the panel can auto-scroll.
    @Published var tick = 0

    private var task: Task<Void, Never>?

    init(source: String, origin: SourceOrigin, context: SourceContext = SourceContext(), mode: Mode? = nil, editingSource: Bool = false) {
        self.id = UUID()
        self.createdAt = Date()
        self.source = source
        self.origin = origin
        self.context = context
        self.mode = mode ?? AppSettings.shared.defaultMode
        self.editingSource = editingSource
    }

    /// Rebuilds a session from a saved history entry.
    init(entry: HistoryEntry) {
        self.id = entry.id
        self.createdAt = entry.date
        self.source = entry.source
        self.origin = entry.origin
        self.context = SourceContext(appName: entry.appName, windowTitle: entry.windowTitle)
        var outputs: [Mode: String] = [:]
        for (key, value) in entry.outputs { if let mode = Mode(rawValue: key) { outputs[mode] = value } }
        self.outputs = outputs
        self.turns = entry.turns
        self.mode = outputs.keys.first ?? AppSettings.shared.defaultMode
        self.editingSource = false
    }

    var currentOutput: String { outputs[mode] ?? "" }

    var hasSource: Bool { !source.trimmed.isEmpty }

    func run(_ mode: Mode, force: Bool = false) {
        self.mode = mode
        guard hasSource else { return }
        if !force, let existing = outputs[mode], !existing.isEmpty || streamingMode == mode { return }
        cancel()
        error = nil
        needsKey = false
        outputs[mode] = ""
        let messages = Prompts.messages(mode: mode, source: source, context: context, settings: AppSettings.shared)
        stream(messages, mode: mode) { [weak self] chunk in
            self?.outputs[mode, default: ""] += chunk
        } onFail: { [weak self] in
            if self?.outputs[mode]?.isEmpty == true { self?.outputs[mode] = nil }
        }
    }

    func ask(_ question: String) {
        let q = question.trimmed
        guard !q.isEmpty, hasSource else { return }
        cancel()
        error = nil
        let messages = Prompts.followUpMessages(mode: mode, source: source, context: context, previousOutput: currentOutput,
                                                turns: turns, question: q, settings: AppSettings.shared)
        turns.append(ChatTurn(question: q, answer: ""))
        let index = turns.count - 1
        stream(messages, mode: nil) { [weak self] chunk in
            guard let self, index < self.turns.count else { return }
            self.turns[index].answer += chunk
        } onFail: { [weak self] in
            guard let self, index < self.turns.count, self.turns[index].answer.isEmpty else { return }
            self.turns.remove(at: index)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isStreaming = false
        streamingMode = nil
    }

    private func stream(_ messages: [ChatMessage], mode: Mode?, onChunk: @escaping (String) -> Void, onFail: @escaping () -> Void) {
        isStreaming = true
        streamingMode = mode
        let config = AppSettings.shared.llmConfig
        task = Task { @MainActor [weak self] in
            do {
                for try await chunk in LLMClient.streamChat(config: config, messages: messages) {
                    onChunk(chunk)
                    self?.tick &+= 1
                }
                self?.finish()
            } catch is CancellationError {
                self?.isStreaming = false
            } catch {
                guard let self else { return }
                self.isStreaming = false
                self.streamingMode = nil
                if Task.isCancelled { return }
                onFail()
                self.error = error.localizedDescription
                self.needsKey = (error as? LLMError)?.isMissingKey ?? false
            }
        }
    }

    private func finish() {
        isStreaming = false
        streamingMode = nil
        HistoryStore.shared.save(self)
    }
}
