from pathlib import Path


def replace(path: str, old: str, new: str):
    p = Path(path)
    text = p.read_text()
    if old not in text:
        raise SystemExit(f"Pattern not found in {path}: {old[:180]!r}")
    p.write_text(text.replace(old, new, 1))

# -----------------------------------------------------------------------------
# 1) AUDIO: restore the clean unity PCM path used by the early working builds.
#    Keep the modern playback queue tracking and barge-in logic, but stop clipping the
#    Gemini stream before iOS voice processing. Voice-processing ducking is handled below.
# -----------------------------------------------------------------------------
replace(
    "OpenVision/Services/Audio/AudioPlaybackService.swift",
    '''    // MARK: - Format / gain\n\n    /// Expected input sample rate (from Gemini)\n    var inputSampleRate: Double = Double(Constants.GeminiLive.outputSampleRate)\n\n    /// The Gemini native PCM stream is noticeably quieter than normal iPhone media even when the\n    /// hardware volume is at 100%. Route forcing cannot fix source amplitude, so give built-in\n    /// iPhone playback a controlled software boost. External Bluetooth/glasses audio is left at\n    /// unity gain because those devices have their own gain characteristics.\n    private let phoneSoftwareGain: Float = 2.5\n''',
    '''    // MARK: - Format\n\n    /// Expected input sample rate (from Gemini)\n    var inputSampleRate: Double = Double(Constants.GeminiLive.outputSampleRate)\n'''
)

replace(
    "OpenVision/Services/Audio/AudioPlaybackService.swift",
    '''        // The phone route is confirmed as loudspeaker, yet Gemini PCM can still be far below normal\n        // media loudness. Boost ONLY the built-in iPhone output and hard-limit just below full scale\n        // to avoid digital overflow/clipping. This preserves Bluetooth/glasses level unchanged.\n        let playbackSamples: [Float]\n        if AudioSessionManager.shared.isUsingBuiltInOutput {\n            playbackSamples = applyPhoneSoftwareGain(resampledSamples)\n            if scheduledBufferCount == 0 {\n                let inputPeak = peak(of: resampledSamples)\n                let outputPeak = peak(of: playbackSamples)\n                DiagnosticLogger.shared.log(\n                    "Audio",\n                    "Phone PCM gain=\\(String(format: \"%.1f\", phoneSoftwareGain))x inputPeak=\\(String(format: \"%.3f\", inputPeak)) outputPeak=\\(String(format: \"%.3f\", outputPeak))"\n                )\n            }\n        } else {\n            playbackSamples = resampledSamples\n        }\n''',
    '''        // Keep Gemini PCM at unity gain, matching the clean playback path from builds 12/13.\n        // The build-21 2.5x hard-limited boost clipped the waveform but could not overcome the\n        // downstream voice-processing ducking, producing exactly the \"estourado mas baixo\" symptom.\n        let playbackSamples = resampledSamples\n        if scheduledBufferCount == 0 {\n            DiagnosticLogger.shared.log(\n                "Audio",\n                "PCM unity gain peak=\\(String(format: \"%.3f\", peak(of: playbackSamples))) route=\\(AudioSessionManager.shared.currentRouteDescription)"\n            )\n        }\n'''
)

replace(
    "OpenVision/Services/Audio/AudioPlaybackService.swift",
    '''    private func applyPhoneSoftwareGain(_ samples: [Float]) -> [Float] {\n        samples.map { sample in\n            let boosted = sample * phoneSoftwareGain\n            return min(0.98, max(-0.98, boosted))\n        }\n    }\n\n''',
    ''''''
)

# Keep AEC/barge-in, but tell Apple's Voice Processing to apply only minimum ducking to the
# separate Gemini playback engine. This targets the downstream attenuation without undoing echo
# cancellation, which is what made interruption reliable.
replace(
    "OpenVision/Services/Voice/VoiceCommandService.swift",
    '''                try inputNode.setVoiceProcessingEnabled(true)\n                DiagnosticLogger.shared.log("Audio", "Voice processing enabled (AEC) on iPhone mic")\n                AudioSessionManager.shared.enforcePhoneSpeakerRoute()\n''',
    '''                try inputNode.setVoiceProcessingEnabled(true)\n                inputNode.voiceProcessingOtherAudioDuckingConfiguration =\n                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(\n                        enableAdvancedDucking: ObjCBool(true),\n                        duckingLevel: .min\n                    )\n                DiagnosticLogger.shared.log("Audio", "Voice processing enabled (AEC); other-audio ducking=min")\n                AudioSessionManager.shared.enforcePhoneSpeakerRoute()\n'''
)

# -----------------------------------------------------------------------------
# 2) WEB SEARCH: wire Gemini Live's native web_search tool to the Web Search provider the UI
#    already configures (Tavily when a key exists; otherwise DuckDuckGo). The previous bridge
#    ignored Settings > Web Search entirely and kept calling Gemini Google Search directly.
# -----------------------------------------------------------------------------
Path("OpenVision/Services/NativeTools/WebSearchTool.swift").write_text(r'''// OpenVision - WebSearchTool.swift
// Current-information search bridge for JARVIS.
//
// IMPORTANT: this tool intentionally delegates to WebSearchService so Settings > Web Search is
// the source of truth. Tavily is used when the user configured a key; otherwise the existing
// keyless DuckDuckGo pipeline is used. Gemini Live only receives the returned findings.

import Foundation

struct WebSearchTool: NativeTool {
    let name = "web_search"
    let description = "Search the current internet for up-to-date information using the provider configured in Settings > Web Search. Use for explicit pesquisar/buscar requests and time-sensitive facts such as sports scores/schedules, news, weather, prices, releases, current office-holders, or recent events. When the request uses relative dates such as hoje/ontem/amanhã, include the corresponding absolute date in the query when possible."

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "query": [
                "type": "string",
                "description": "A concise web-search query. Include team/person/topic plus an absolute date for time-sensitive questions when known."
            ]
        ],
        "required": ["query"]
    ]

    func execute(args: [String: Any]) async throws -> String {
        guard let rawQuery = args["query"] as? String else { throw WebSearchError.invalidQuery }
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw WebSearchError.invalidQuery }

        let provider = await MainActor.run {
            SettingsManager.shared.settings.tavilyAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "DuckDuckGo"
                : "Tavily→DuckDuckGo"
        }
        await MainActor.run {
            DiagnosticLogger.shared.log("WebSearch", "Searching provider=\(provider)")
        }

        let result = await WebSearchService.search(query)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !result.isEmpty else {
            await MainActor.run {
                DiagnosticLogger.shared.log("WebSearch", "No usable results provider=\(provider)")
            }
            throw WebSearchError.emptyResult(provider)
        }

        await MainActor.run {
            DiagnosticLogger.shared.log("WebSearch", "Search completed provider=\(provider) chars=\(result.count)")
        }
        return result
    }
}

private enum WebSearchError: LocalizedError {
    case invalidQuery
    case emptyResult(String)

    var errorDescription: String? {
        switch self {
        case .invalidQuery:
            return "A pesquisa precisa de uma pergunta."
        case .emptyResult(let provider):
            return "A pesquisa via \(provider) não retornou resultados utilizáveis."
        }
    }
}
''')

# Make the settings screen explicit about what it controls.
replace(
    "OpenVision/Views/Settings/WebSearchSettingsView.swift",
    '''            } footer: {\n                Text("Tavily is a search API built for AI assistants — it returns real, current content (news, prices, scores) rather than just links, which is what lets the model actually answer live questions. The free tier covers everyday use. When set, it's the primary web-search source; DuckDuckGo stays the keyless fallback.")\n            }\n''',
    '''            } footer: {\n                Text("This setting powers JARVIS's web_search tool. Tavily returns current AI-friendly content; without a Tavily key, JARVIS uses the built-in keyless DuckDuckGo search as fallback.")\n            }\n'''
)

# -----------------------------------------------------------------------------
# 3) HISTORY: Gemini Live output transcription arrives as fragments. Append them instead of
#    overwriting aiTranscript on each fragment, and don't add the user message twice.
# -----------------------------------------------------------------------------
replace(
    "OpenVision/Views/VoiceAgent/VoiceAgentViewModel.swift",
    '''            self.userTranscript = command\n\n            // History: every captured command is a user message (Meta AI records all glasses\n''',
    '''            self.userTranscript = command\n            // Gemini Live output transcription is streamed in small fragments. Reset the reply\n            // accumulator at the start of EVERY captured command so History stores one complete\n            // assistant message for this turn rather than the final fragment only.\n            self.aiTranscript = ""\n            self.historyLastLiveReply = ""\n\n            // History: every captured command is a user message (Meta AI records all glasses\n'''
)

replace(
    "OpenVision/Views/VoiceAgent/VoiceAgentViewModel.swift",
    '''        GeminiLiveService.shared.onOutputTranscription = { [weak self] (text: String) in\n            self?.aiTranscript = text\n        }\n''',
    '''        GeminiLiveService.shared.onOutputTranscription = { [weak self] (text: String) in\n            guard let self else { return }\n            // Gemini sends outputAudioTranscription incrementally (often word/phrase fragments).\n            // Preserve the full reply for the live UI and persisted History.\n            self.aiTranscript += text\n        }\n'''
)

replace(
    "OpenVision/Views/VoiceAgent/VoiceAgentViewModel.swift",
    '''        guard !reply.isEmpty, reply != historyLastLiveReply else { return }\n        if !user.isEmpty { ConversationManager.shared.addUserMessage(user) }\n        ConversationManager.shared.addAssistantMessage(reply)\n''',
    '''        guard !reply.isEmpty, reply != historyLastLiveReply else { return }\n        // Normal wake-word commands were already persisted by onCommandCaptured. Live-video /\n        // realtime paths bypass that callback, so only those need the user message added here.\n        if !historyAwaitingReply, !user.isEmpty { ConversationManager.shared.addUserMessage(user) }\n        ConversationManager.shared.addAssistantMessage(reply)\n'''
)

# -----------------------------------------------------------------------------
# 4) CUSTOM INSTRUCTIONS + MEMORIES: one-time JARVIS profile seed. Never overwrite user edits,
#    API keys, or existing memory values. A migration marker prevents re-populating deleted items.
# -----------------------------------------------------------------------------
replace(
    "OpenVision/Models/AppSettings.swift",
    '''    /// Key-value memories the AI can read and manage\n    var memories: [String: String] = [:]\n\n    // MARK: - Advanced Settings\n''',
    '''    /// Key-value memories the AI can read and manage\n    var memories: [String: String] = [:]\n\n    /// One-time migration marker for the Project JARVIS starter profile. This prevents the app\n    /// from recreating memories/instructions the user later edits or deliberately deletes.\n    var jarvisProfileSeedVersion: Int = 0\n\n    // MARK: - Advanced Settings\n'''
)

replace(
    "OpenVision/Managers/SettingsManager.swift",
    '''        // Load existing settings or create defaults\n        settings = Self.loadSettings(from: settingsURL)\n\n        print("[SettingsManager] Initialized with settings from: \\(settingsURL.path)")\n''',
    '''        // Load existing settings or create defaults, then apply the Project JARVIS starter\n        // profile exactly once. Existing user text/memories always win.\n        var loaded = Self.loadSettings(from: settingsURL)\n        let seededProfile = Self.seedJarvisProfileIfNeeded(&loaded)\n        settings = loaded\n        if seededProfile { Self.persistSettings(loaded, to: settingsURL) }\n\n        print("[SettingsManager] Initialized with settings from: \\(settingsURL.path)")\n'''
)

replace(
    "OpenVision/Managers/SettingsManager.swift",
    '''    private static func loadSettings(from url: URL) -> AppSettings {\n''',
    '''    private static func persistSettings(_ settings: AppSettings, to url: URL) {\n        do {\n            let encoder = JSONEncoder()\n            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]\n            try encoder.encode(settings).write(to: url, options: .atomic)\n            print("[SettingsManager] Seeded Project JARVIS profile defaults")\n        } catch {\n            print("[SettingsManager] Failed to persist seeded JARVIS profile: \\(error)")\n        }\n    }\n\n    /// Fill the Settings UI with useful JARVIS defaults once, without ever overwriting user edits.\n    private static func seedJarvisProfileIfNeeded(_ settings: inout AppSettings) -> Bool {\n        guard settings.jarvisProfileSeedVersion < 1 else { return false }\n\n        if settings.userPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {\n            settings.userPrompt = """\n            Você é o JARVIS, meu assistente pessoal do Projeto JARVIS.\n            Responda em português brasileiro, salvo se eu pedir explicitamente outro idioma.\n            Priorize respostas curtas, naturais e úteis para uso por voz e sem as mãos.\n            Quando eu pedir uma ação no iPhone e existir uma ferramenta nativa, execute a ferramenta em vez de apenas explicar como fazer.\n            Para fatos atuais — como placares, próximos jogos, notícias, preços, clima, lançamentos e informações que podem ter mudado — use web_search antes de responder.\n            Nunca afirme que executou uma ação se a ferramenta não confirmou sucesso.\n            Para fatos sobre mim ou sobre o Projeto JARVIS, use Memories e My Documents quando apropriado e não invente informações ausentes.\n            Diferencie claramente o que você sabe do que realmente consegue executar no iPhone ou nos óculos Meta/Ray-Ban Meta.\n            """\n        }\n\n        let starterMemories: [String: String] = [\n            "idioma_preferido": "Português brasileiro (pt-BR).",\n            "projeto_principal": "Projeto JARVIS: assistente pessoal hands-free integrado ao iPhone e aos óculos Meta/Ray-Ban Meta.",\n            "hardware_alvo": "Meta/Ray-Ban Meta é o óculos oficial do Projeto JARVIS; o iPhone funciona como hub principal.",\n            "estilo_de_resposta": "Direto, natural e técnico quando necessário, sem exageros; respostas por voz devem ser objetivas.",\n            "objetivo_de_uso": "Usar o JARVIS no dia a dia pelos óculos para conversar, perceber contexto e executar ações reais no iPhone.",\n            "fluxo_de_desenvolvimento": "O app iOS é desenvolvido no Windows, compilado no GitHub Actions e instalado no iPhone por Sideloadly; não depende de Xcode/Mac no fluxo atual."\n        ]\n        for (key, value) in starterMemories where settings.memories[key] == nil {\n            settings.memories[key] = value\n        }\n\n        settings.jarvisProfileSeedVersion = 1\n        return true\n    }\n\n    private static func loadSettings(from url: URL) -> AppSettings {\n'''
)

# -----------------------------------------------------------------------------
# 5) BUILD NUMBER / NOTES
# -----------------------------------------------------------------------------
replace("project.yml", '    CURRENT_PROJECT_VERSION: "21"\n', '    CURRENT_PROJECT_VERSION: "22"\n')

notes = Path("JARVIS_BUILD_NOTES.md")
text = notes.read_text()
header = "# Projeto JARVIS build notes\n\n"
if not text.startswith(header):
    raise SystemExit("Unexpected build notes header")
b22 = '''## Build 22\n\n- Audio: compared the current path with the clean build-12/13 PCM path; removed the build-21 2.5x hard-limited software gain that caused clipping/\"chiado\". Gemini PCM is back at unity gain.\n- Audio: kept AVAudioEngine voice processing/AEC and all working barge-in behavior, but configured voice-processing other-audio ducking to minimum so the separate Gemini playback engine is not heavily attenuated.\n- Web search: fixed the architecture mismatch where Settings showed DuckDuckGo/Tavily while the Gemini `web_search` tool ignored that setting and called Google grounding directly. `web_search` now delegates to the existing WebSearchService: Tavily when configured, otherwise keyless DuckDuckGo.\n- History: Gemini output-transcription fragments are accumulated into the complete assistant reply before persistence; normal wake-word user messages are no longer duplicated by the live-turn recorder.\n- Custom Instructions: one-time starter instructions are populated automatically only when the field is empty.\n- Memories: one-time Project JARVIS starter memories are populated without overwriting existing memory values; a migration marker prevents deleted/edited memories from being recreated every launch.\n- App build number is 22.\n\n'''
notes.write_text(header + b22 + text[len(header):])

# One-shot helper cleanup: final source commit should contain only product changes.
Path(".github/workflows/apply-build22-history-web-audio.yml").unlink(missing_ok=True)
Path("scripts/apply_build22_history_web_audio.py").unlink(missing_ok=True)
