import Foundation

struct SourceContext {
    var appName: String?
    var windowTitle: String?
}

enum Prompts {
    private static func styleNote(_ lang: String) -> String {
        let l = lang.lowercased()
        if l.contains("egyptian") {
            return "Write in natural Egyptian Arabic (العامية المصرية) that is clear and easy to read."
        }
        if l.contains("arab") {
            return "Write in clear, modern standard Arabic (الفصحى الواضحة), not a dialect."
        }
        return "Write in clear, natural \(lang)."
    }

    static func system(for mode: Mode, settings: AppSettings) -> String {
        let lang = settings.targetLanguage
        let style = styleNote(lang)
        var prompt: String
        switch mode {
        case .translate:
            prompt = """
            You are a professional translator working inside a desktop app used by tech content creators.
            Translate the user's text into \(lang). \(style)
            Rules:
            - Be faithful and natural.
            - Keep product names, model names, code, CLI commands and well-established technical terms in English when that reads more naturally; you may add a short \(lang) gloss in parentheses the first time a term appears.
            - Preserve the structure of the original (paragraphs, lists, headings).
            - Output ONLY the translation. No preamble, no notes.
            """
        case .explain:
            prompt = """
            You are an assistant inside a desktop app used by a tech content creator who presents to a \(lang)-speaking audience.
            Do NOT translate the text literally. Instead, EXPLAIN it in \(lang): what it means, what's new or important, and why the audience should care — as if the creator is explaining it on camera. \(style)
            Rules:
            - Short paragraphs or bullet points ("- ").
            - Keep technical terms, product and model names in English, with a brief \(lang) gloss in parentheses on first mention.
            - If the text contains numbers, benchmarks or comparisons, spell out what they mean in practice.
            - No preamble like "this text talks about"; start directly with the explanation.
            """
        case .simplify:
            prompt = """
            You are an assistant inside a desktop app. Explain the user's text in very simple \(lang), as if to a smart beginner with no technical background. \(style)
            Rules:
            - Everyday words and, when helpful, one short real-world analogy.
            - Under ~150 words.
            - Keep unavoidable technical terms in English with a simple \(lang) explanation in parentheses.
            - No preamble; start directly.
            """
        case .summarize:
            prompt = """
            You are an assistant inside a desktop app. Summarize the user's text in \(lang). \(style)
            Rules:
            - 3–6 concise bullet points using "- ", most important first.
            - Keep technical terms and product names in English where natural.
            - Bullets only: no preamble, no closing sentence.
            """
        case .script:
            prompt = """
            You write for a tech content creator who records videos for a \(lang)-speaking audience.
            Turn the user's text into a ready-to-read spoken script segment in \(lang). \(style) It must sound natural when read aloud, not stiff.
            Structure:
            - One strong opening hook line.
            - The explanation, in short spoken sentences.
            - Why it matters to the viewer.
            - One short transition line to wrap up.
            Rules:
            - 45–120 seconds when read aloud.
            - Keep product and model names in English.
            - No headings, no stage directions, no emojis, no bullet points — just the lines to say, one paragraph per beat.
            """
        case .post:
            prompt = """
            You write social media posts for a tech content creator with a \(lang)-speaking audience.
            Based on the user's text, write in \(lang): \(style)
            1. An X (Twitter) post under 280 characters with a strong hook (at most 2 hashtags).
            2. A LinkedIn-style post of 80–150 words that explains the news and why it matters.
            Label the two parts with short bold headings in \(lang). Keep product and model names in English. Output only the two posts.
            """
        }

        if !settings.glossary.isEmpty {
            let lines = settings.glossary
                .filter { !$0.term.trimmed.isEmpty && !$0.rendering.trimmed.isEmpty }
                .map { "- \($0.term.trimmed) → \($0.rendering.trimmed)" }
            if !lines.isEmpty {
                prompt += "\n\nGlossary — always render these terms exactly like this:\n" + lines.joined(separator: "\n")
            }
        }
        if !settings.customInstructions.trimmed.isEmpty {
            prompt += "\n\nAdditional preferences from the user:\n" + settings.customInstructions.trimmed
        }
        return prompt
    }

    private static func userMessage(source: String, context: SourceContext) -> String {
        var message = ""
        let app = context.appName?.trimmed ?? ""
        let title = context.windowTitle?.trimmed ?? ""
        if !app.isEmpty || !title.isEmpty {
            message += "Context — the text came from"
            if !app.isEmpty { message += " the app \"\(app)\"" }
            if !title.isEmpty { message += ", window \"\(title)\"" }
            message += ".\n\n"
        }
        message += "Text:\n\"\"\"\n\(source)\n\"\"\""
        return message
    }

    static func messages(mode: Mode, source: String, context: SourceContext, settings: AppSettings) -> [ChatMessage] {
        [
            ChatMessage(role: "system", content: system(for: mode, settings: settings)),
            ChatMessage(role: "user", content: userMessage(source: source, context: context)),
        ]
    }

    static func followUpMessages(mode: Mode, source: String, context: SourceContext, previousOutput: String,
                                 turns: [ChatTurn], question: String, settings: AppSettings) -> [ChatMessage] {
        let lang = settings.targetLanguage
        var system = system(for: mode, settings: settings)
        system += """


        The user may now ask follow-up questions about the text. Answer each one in \(lang), clearly and concisely, \
        grounded in the original text. If the text doesn't contain the answer, you may use general knowledge but say so briefly.
        """
        var result: [ChatMessage] = [
            ChatMessage(role: "system", content: system),
            ChatMessage(role: "user", content: userMessage(source: source, context: context)),
        ]
        if !previousOutput.trimmed.isEmpty {
            result.append(ChatMessage(role: "assistant", content: previousOutput))
        }
        for turn in turns where !turn.answer.trimmed.isEmpty {
            result.append(ChatMessage(role: "user", content: turn.question))
            result.append(ChatMessage(role: "assistant", content: turn.answer))
        }
        result.append(ChatMessage(role: "user", content: question))
        return result
    }
}
