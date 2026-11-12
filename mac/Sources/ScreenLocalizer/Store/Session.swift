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
    /// True while ScreenOCR is recognizing pixels for an already-opened optimistic panel.
    @Published var isPreparing: Bool
    /// Bumped on coalesced stream frames so the panel can auto-scroll without per-token thrashing.
    @Published var tick = 0

    private var task: Task<Void, Never>?
    private var activeStreamID: UUID?

    init(source: String, origin: SourceOrigin, context: SourceContext = SourceContext(), mode: Mode? = nil, editingSource: Bool = false, isPreparing: Bool = false) {
        self.id = UUID()
        self.createdAt = Date()
        self.source = source
        self.origin = origin
        self.context = context
        self.mode = mode ?? AppSettings.shared.defaultMode
        self.editingSource = editingSource
        self.isPreparing = isPreparing
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
        self.mode = Mode.allCases.first { outputs[$0] != nil } ?? AppSettings.shared.defaultMode
        self.editingSource = false
        self.isPreparing = false
    }

    var currentOutput: String { outputs[mode] ?? "" }

    var hasSource: Bool { !source.trimmed.isEmpty }

    func finishPreparingAndRun(source: String) {
        self.source = source
        self.isPreparing = false
        run(mode)
    }

    func run(_ mode: Mode, force: Bool = false) {
        self.mode = mode
        guard hasSource else { return }
        if !force, let existing = outputs[mode], !existing.isEmpty || streamingMode == mode { return }

        let settings = AppSettings.shared
        let cacheKey = TranslationCache.makeKey(mode: mode, source: source, settings: settings)
        if !force, let cached = TranslationCache.shared.get(cacheKey), !cached.isEmpty {
            cancel()
            error = nil
            needsKey = false
            outputs[mode] = cached
            HistoryStore.shared.save(self)
            return
        }

        cancel()
        error = nil
        needsKey = false
        outputs[mode] = ""
        let messages = Prompts.messages(mode: mode, source: source, context: context, settings: settings)
        stream(messages, mode: mode, cacheKey: cacheKey) { [weak self] chunk in
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
        stream(messages, mode: nil, cacheKey: nil) { [weak self] chunk in
            guard let self, index < self.turns.count else { return }
            self.turns[index].answer += chunk
        } onFail: { [weak self] in
            guard let self, index < self.turns.count, self.turns[index].answer.isEmpty else { return }
            self.turns.remove(at: index)
        }
    }

    func cancel() {
        activeStreamID = nil
        task?.cancel()
        task = nil
        isStreaming = false
        streamingMode = nil
    }

    private func flushPendingBatch(
        _ pendingBuffer: inout String,
        streamID: UUID,
        onChunk: (String) -> Void,
        lastFlush: inout ContinuousClock.Instant
    ) {
        guard !pendingBuffer.isEmpty, activeStreamID == streamID else { return }
        let batch = pendingBuffer
        pendingBuffer = ""
        onChunk(batch)
        if !turns.isEmpty { tick &+= 1 }
        lastFlush = ContinuousClock.now
    }

    private func stream(_ messages: [ChatMessage], mode: Mode?, cacheKey: String?, onChunk: @escaping (String) -> Void, onFail: @escaping () -> Void) {
        let streamID = UUID()
        activeStreamID = streamID
        isStreaming = true
        streamingMode = mode
        let config = AppSettings.shared.llmConfig
        task = Task { @MainActor [weak self] in
            var pendingBuffer = ""
            var emittedFirstChunk = false
            var lastFlush = ContinuousClock.now
            let frameInterval = Duration.milliseconds(16)

            do {
                for try await chunk in LLMClient.streamChat(config: config, messages: messages) {
                    guard let self, self.activeStreamID == streamID else { return }
                    if !emittedFirstChunk {
                        // Paint the very first token with zero buffering delay for minimum TTFT.
                        emittedFirstChunk = true
                        onChunk(chunk)
                        if !self.turns.isEmpty { self.tick &+= 1 }
                        lastFlush = ContinuousClock.now
                    } else {
                        pendingBuffer += chunk
                        if ContinuousClock.now - lastFlush >= frameInterval {
                            self.flushPendingBatch(&pendingBuffer, streamID: streamID, onChunk: onChunk, lastFlush: &lastFlush)
                        }
                    }
                }
                if let self {
                    self.flushPendingBatch(&pendingBuffer, streamID: streamID, onChunk: onChunk, lastFlush: &lastFlush)
                }
                guard let self, self.activeStreamID == streamID else { return }
                if let mode, let cacheKey, let finished = self.outputs[mode], !finished.isEmpty {
                    TranslationCache.shared.set(finished, for: cacheKey)
                }
                self.finish()
            } catch is CancellationError {
                guard let self, self.activeStreamID == streamID else { return }
                self.isStreaming = false
                self.streamingMode = nil
            } catch {
                if let self {
                    self.flushPendingBatch(&pendingBuffer, streamID: streamID, onChunk: onChunk, lastFlush: &lastFlush)
                }
                guard let self, self.activeStreamID == streamID else { return }
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
        activeStreamID = nil
        isStreaming = false
        streamingMode = nil
        HistoryStore.shared.save(self)
    }
}
