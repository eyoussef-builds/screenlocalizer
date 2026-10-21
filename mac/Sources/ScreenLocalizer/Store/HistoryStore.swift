import Foundation
import Combine

struct HistoryEntry: Codable, Identifiable, Hashable {
    var id: UUID
    var date: Date
    var origin: SourceOrigin
    var appName: String?
    var windowTitle: String?
    var source: String
    var targetLanguage: String
    /// Mode raw value → generated text.
    var outputs: [String: String]
    var turns: [ChatTurn]

    var modes: [Mode] { Mode.allCases.filter { outputs[$0.rawValue]?.isEmpty == false } }

    var title: String {
        let firstLine = source.trimmed.components(separatedBy: .newlines).first ?? ""
        return firstLine.count > 90 ? String(firstLine.prefix(90)) + "…" : firstLine
    }

    static func == (lhs: HistoryEntry, rhs: HistoryEntry) -> Bool { lhs.id == rhs.id && lhs.outputs == rhs.outputs && lhs.turns == rhs.turns }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension ChatTurn: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Saves every finished result to ~/Library/Application Support/ScreenLocalizer/history.json.
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    static let maxEntries = 3000

    @Published private(set) var entries: [HistoryEntry] = []
    private var saveWork: DispatchWorkItem?

    private var fileURL: URL {
        // Test runs (SCREENLOCALIZER_DEBUG=1) keep their own history so they never touch real data.
        let folder = DebugHooks.enabled ? "ScreenLocalizer-Debug" : "ScreenLocalizer"
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("history.json")
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([HistoryEntry].self, from: data)) ?? []
    }

    func save(_ session: Session) {
        guard AppSettings.shared.historyEnabled, session.hasSource else { return }
        var outputs: [String: String] = [:]
        for (mode, text) in session.outputs where !text.trimmed.isEmpty { outputs[mode.rawValue] = text }
        guard !outputs.isEmpty || !session.turns.isEmpty else { return }
        let entry = HistoryEntry(id: session.id, date: session.createdAt, origin: session.origin,
                                 appName: session.context.appName, windowTitle: session.context.windowTitle,
                                 source: session.source, targetLanguage: AppSettings.shared.targetLanguage,
                                 outputs: outputs, turns: session.turns.filter { !$0.answer.trimmed.isEmpty })
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries.insert(entry, at: 0)
            if entries.count > HistoryStore.maxEntries { entries.removeLast(entries.count - HistoryStore.maxEntries) }
        }
        scheduleWrite()
    }

    func delete(_ ids: Set<UUID>) {
        entries.removeAll { ids.contains($0.id) }
        scheduleWrite()
    }

    func clear() {
        entries = []
        scheduleWrite()
    }

    private func scheduleWrite() {
        saveWork?.cancel()
        let snapshot = entries
        let url = fileURL
        let work = DispatchWorkItem {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: Markdown export

    static func markdown(for entries: [HistoryEntry]) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        var md = "# ScreenLocalizer — \(dateFormatter.string(from: Date()))\n\n"
        for (index, entry) in entries.enumerated() {
            var meta = dateFormatter.string(from: entry.date)
            if let app = entry.appName, !app.isEmpty { meta += " · \(app)" }
            if let title = entry.windowTitle, !title.isEmpty { meta += " · \(title)" }
            md += "## \(index + 1). \(entry.title)\n\n_\(meta)_\n\n"
            let quoted = entry.source.trimmed.components(separatedBy: .newlines).map { "> \($0)" }.joined(separator: "\n")
            md += "\(quoted)\n\n"
            for mode in entry.modes {
                md += "### \(mode.label)\n\n\(entry.outputs[mode.rawValue]!.trimmed)\n\n"
            }
            for turn in entry.turns {
                md += "**\(L("Q:"))** \(turn.question)\n\n\(turn.answer.trimmed)\n\n"
            }
            md += "---\n\n"
        }
        return md
    }
}
