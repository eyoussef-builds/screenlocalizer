import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct HistoryView: View {
    @ObservedObject var store = HistoryStore.shared
    @ObservedObject var settings = AppSettings.shared
    @State private var query = ""
    @State private var selection: Set<UUID> = []
    @State private var modeFilter: Mode?
    @State private var confirmClear = false

    private var filtered: [HistoryEntry] {
        store.entries.filter { entry in
            if let modeFilter, entry.outputs[modeFilter.rawValue] == nil { return false }
            guard !query.trimmed.isEmpty else { return true }
            let q = query.lowercased()
            return entry.source.lowercased().contains(q)
                || entry.outputs.values.contains { $0.lowercased().contains(q) }
                || (entry.appName?.lowercased().contains(q) ?? false)
                || (entry.windowTitle?.lowercased().contains(q) ?? false)
        }
    }

    private var selectedEntries: [HistoryEntry] { filtered.filter { selection.contains($0.id) } }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(filtered) { entry in
                    HistoryRow(entry: entry).tag(entry.id)
                }
            }
            .searchable(text: $query, placement: .sidebar, prompt: L("Search history"))
            .navigationSplitViewColumnWidth(min: 260, ideal: 320)
            .overlay {
                if store.entries.isEmpty {
                    ContentUnavailableView(L("No history yet"), systemImage: "clock",
                                           description: Text("Results you generate are saved here automatically."))
                }
            }
        } detail: {
            if selectedEntries.count == 1, let entry = selectedEntries.first {
                HistoryDetail(entry: entry)
            } else if selectedEntries.count > 1 {
                ContentUnavailableView(LF("%d items selected", selectedEntries.count), systemImage: "square.stack",
                                       description: Text("Export them together as one Markdown script."))
            } else {
                ContentUnavailableView(L("Select an item"), systemImage: "text.bubble")
            }
        }
        .toolbar {
            ToolbarItem {
                Picker(L("Mode"), selection: $modeFilter) {
                    Text("All modes").tag(Mode?.none)
                    ForEach(Mode.allCases) { Text($0.label).tag(Mode?.some($0)) }
                }
                .pickerStyle(.menu)
                .frame(width: 150)
            }
            ToolbarItem {
                Menu {
                    Button(L("Export Selected…")) { export(selectedEntries) }.disabled(selectedEntries.isEmpty)
                    Button(L("Export Today…")) { export(filtered.filter { Calendar.current.isDateInToday($0.date) }) }
                    Button(L("Export All Shown…")) { export(filtered) }.disabled(filtered.isEmpty)
                } label: {
                    Label(L("Export"), systemImage: "square.and.arrow.up")
                }
            }
            ToolbarItem {
                Button {
                    store.delete(selection)
                    selection = []
                } label: {
                    Label(L("Delete"), systemImage: "trash")
                }
                .disabled(selection.isEmpty)
                .help(L("Delete selected items"))
            }
            ToolbarItem {
                Menu {
                    Button(L("Clear All History…"), role: .destructive) { confirmClear = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog(L("Delete all history?"), isPresented: $confirmClear) {
            Button(L("Delete All"), role: .destructive) {
                store.clear()
                selection = []
            }
        } message: {
            Text("This can't be undone.")
        }
        .frame(minWidth: 760, minHeight: 480)
    }

    private func export(_ entries: [HistoryEntry]) {
        guard !entries.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        panel.nameFieldStringValue = "ScreenLocalizer \(formatter.string(from: Date())).md"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try HistoryStore.markdown(for: entries).write(to: url, atomically: true, encoding: .utf8)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.title).lineLimit(2).font(.system(size: 13, weight: .medium))
                .environment(\.layoutDirection, .leftToRight)
            HStack(spacing: 6) {
                Image(systemName: entry.origin.symbol)
                Text(entry.date.formatted(.relative(presentation: .named)))
                if let app = entry.appName, !app.isEmpty { Text("· \(app)").lineLimit(1) }
            }
            .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ForEach(entry.modes) { mode in
                    Text(mode.label)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Brand.indigo.opacity(0.18)))
                        .foregroundStyle(Brand.accentText)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct HistoryDetail: View {
    let entry: HistoryEntry
    @ObservedObject var settings = AppSettings.shared

    private var rtl: Bool { Languages.isRTL(entry.targetLanguage) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.date.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                        HStack(spacing: 6) {
                            Label(entry.origin.label, systemImage: entry.origin.symbol)
                            if let app = entry.appName, !app.isEmpty { Text("· \(app)") }
                            if let title = entry.windowTitle, !title.isEmpty { Text("· \(title)").lineLimit(1) }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        let session = Session(entry: entry)
                        PanelController.shared.present(session, anchor: nil, autoRun: false)
                    } label: {
                        Label(L("Open in Panel"), systemImage: "macwindow")
                    }
                }

                GroupBox {
                    Text(entry.source)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .environment(\.layoutDirection, .leftToRight)
                } label: {
                    Label(L("Original"), systemImage: "doc.plaintext")
                }

                ForEach(entry.modes) { mode in
                    GroupBox {
                        MarkdownView(text: entry.outputs[mode.rawValue] ?? "", fontSize: 14, rtl: rtl)
                            .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
                    } label: {
                        HStack {
                            Label(mode.label, systemImage: mode.symbol)
                            Spacer()
                            CopyButton(text: entry.outputs[mode.rawValue] ?? "")
                        }
                    }
                }

                if !entry.turns.isEmpty {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(entry.turns) { turn in
                                Text(turn.question).font(.system(size: 13, weight: .semibold))
                                MarkdownView(text: turn.answer, fontSize: 14, rtl: rtl)
                                    .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
                            }
                        }
                    } label: {
                        Label(L("Follow-up questions"), systemImage: "bubble.left.and.bubble.right")
                    }
                }
            }
            .padding(20)
        }
    }
}

private struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            ClipboardWatcher.shared.markOwnChange()
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help(L("Copy"))
    }
}
