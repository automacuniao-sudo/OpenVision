from pathlib import Path


def replace(path, old, new):
    p = Path(path)
    text = p.read_text()
    if old not in text:
        raise SystemExit(f'Pattern not found in {path}: {old[:120]!r}')
    p.write_text(text.replace(old, new, 1))

# 1) Phone audio session: voice-chat mode is required for proper two-way voice processing.
replace(
    'OpenVision/Services/Audio/AudioSessionManager.swift',
    '''        try audioSession.setCategory(\n            .playAndRecord,\n            mode: .default,\n            options: [.defaultToSpeaker, .allowBluetoothA2DP]\n        )\n        try audioSession.setActive(true)\n''',
    '''        try audioSession.setCategory(\n            .playAndRecord,\n            mode: .voiceChat,\n            options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP]\n        )\n        try audioSession.setActive(true)\n'''
)

# 2) Enable AVAudioEngine voice processing (AEC/AGC) on the built-in mic route.
replace(
    'OpenVision/Services/Voice/VoiceCommandService.swift',
    '''        // Get input node\n        let inputNode = audioEngine.inputNode\n        inputNode.removeTap(onBus: 0) // defensive: never install over an existing tap\n''',
    '''        // Get input node. On the iPhone built-in mic route enable AVAudioEngine voice\n        // processing BEFORE the engine starts. This is the system AEC path: audio currently\n        // playing from the device is removed from the microphone signal, so JARVIS can keep\n        // listening for a real barge-in without transcribing its own reply. Do not force this on\n        // the glasses HFP route; camera/HFP coexistence has different constraints.\n        let inputNode = audioEngine.inputNode\n        if AudioSessionManager.shared.isUsingBuiltInMic {\n            do {\n                try inputNode.setVoiceProcessingEnabled(true)\n                DiagnosticLogger.shared.log(\"Audio\", \"Voice processing enabled (AEC) on iPhone mic\")\n            } catch {\n                DiagnosticLogger.shared.log(\"Audio\", \"Voice processing unavailable: \\(error.localizedDescription)\")\n                print(\"[VoiceCommand] Voice processing enable failed: \\(error)\")\n            }\n        }\n        inputNode.removeTap(onBus: 0) // defensive: never install over an existing tap\n'''
)

# 3) Remove the unsafe Build-16 'latest Jarvis anywhere in transcript' heuristic. With speaker
# echo it could treat JARVIS saying its own name as a user interruption and create a feedback loop.
replace(
    'OpenVision/Services/Voice/VoiceCommandService.swift',
    '''            if allowInterrupt,\n               let command = recentInterruptCommand(in: transcription),\n               !command.isEmpty {\n                // While JARVIS speaks, Apple's recognizer also hears the speaker output. The live\n                // transcript therefore often starts with JARVIS' own sentence, with the user's\n                // \"Jarvis, ...\" appended later. Detect the MOST RECENT wake/name marker instead of\n                // requiring it at character zero.\n                print(\"[VoiceCommand] JARVIS barge-in detected: '\\(command)'\")\n                DiagnosticLogger.shared.log(\"Voice\", \"Barge-in follow-up detected: \\(command)\")\n\n                onInterruption?()\n                state = .listening\n                currentTranscription = command\n                hasSpokenThisTurn = true\n                resetSilenceTimer()\n\n                if result.isFinal {\n                    print(\"[VoiceCommand] Barge-in result final, processing command immediately\")\n                    handleCommandComplete(command)\n                }\n                return\n            }\n''',
    '''            if allowInterrupt, interruptPrefixAtStart(transcription) != nil {\n                // AEC should make a deliberate user interruption start with the wake/name phrase.\n                // Requiring the marker at the START is intentionally conservative: if AEC ever\n                // leaks JARVIS' own speech, the assistant saying its own name must not recursively\n                // interrupt itself.\n                let command = extractCommandAfterInterruptPrefix(transcription)\n                guard !command.isEmpty else { return }\n                print(\"[VoiceCommand] JARVIS barge-in detected: '\\(command)'\")\n                DiagnosticLogger.shared.log(\"Voice\", \"Barge-in follow-up detected: \\(command)\")\n\n                onInterruption?()\n                state = .listening\n                currentTranscription = command\n                hasSpokenThisTurn = true\n                resetSilenceTimer()\n\n                if result.isFinal {\n                    print(\"[VoiceCommand] Barge-in result final, processing command immediately\")\n                    handleCommandComplete(command)\n                }\n                return\n            }\n'''
)

# 4) Stop phrases must also be deliberate, not discovered anywhere inside echoed assistant speech.
start = Path('OpenVision/Services/Voice/VoiceCommandService.swift')
text = start.read_text()
a = text.index('    private func isStopPhrase(_ text: String) -> Bool {')
b = text.index('    /// Extract text after the most recent JARVIS/wake marker', a)
new_stop = '''    private func isStopPhrase(_ text: String) -> Bool {\n        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)\n        if lower.contains(\"video\") || lower.contains(\"stream\") { return false }\n\n        // Natural Portuguese order: \"pare Jarvis\". Require it at the beginning so leaked\n        // assistant audio cannot trigger a recursive stop.\n        let reversedStopPhrases = [\n            \"pare jarvis\", \"para jarvis\", \"parar jarvis\", \"silêncio jarvis\", \"silencio jarvis\",\n            \"chega jarvis\", \"cancela jarvis\", \"cancelar jarvis\", \"stop jarvis\"\n        ]\n        if reversedStopPhrases.contains(where: { lower.hasPrefix($0) }) {\n            DiagnosticLogger.shared.log(\"Voice\", \"Barge-in stop detected (stop-before-Jarvis)\")\n            return true\n        }\n\n        // Normal order: \"Jarvis, pare\" / \"Ok Jarvis, silêncio\".\n        guard interruptPrefixAtStart(text) != nil else { return false }\n        let command = extractCommandAfterInterruptPrefix(text).lowercased()\n        let stopWords = [\n            \"stop\", \"be quiet\", \"shut up\", \"silence\", \"quiet\", \"enough\", \"cancel\",\n            \"pare\", \"parar\", \"silêncio\", \"silencio\", \"cala a boca\", \"fica quieto\", \"chega\", \"cancela\", \"cancelar\"\n        ]\n        let matched = stopWords.contains { command == $0 || command.hasPrefix($0 + \" \") }\n        if matched { DiagnosticLogger.shared.log(\"Voice\", \"Barge-in stop detected (Jarvis-before-stop)\") }\n        return matched\n    }\n\n'''
text = text[:a] + new_stop + text[b:]
start.write_text(text)

# 5) Portuguese-first on-device document embeddings for the user's JARVIS/profile PDFs.
replace(
    'OpenVision/Services/Documents/DocumentStore.swift',
    '''    /// Loaded once — NLEmbedding init reads a model from disk.\n    private lazy var embedder = NLEmbedding.sentenceEmbedding(for: .english)\n''',
    '''    /// Loaded once — NLEmbedding init reads a model from disk. Project JARVIS is operated\n    /// primarily in Brazilian Portuguese, so index/search Portuguese documents in their native\n    /// language; keep English as a fallback on devices where the Portuguese asset is unavailable.\n    private lazy var embedder = NLEmbedding.sentenceEmbedding(for: .portuguese)\n        ?? NLEmbedding.sentenceEmbedding(for: .english)\n'''
)

# 6) Make personal/project documents an explicit knowledge source rather than hallucinating.
replace(
    'OpenVision/Services/GeminiLive/GeminiLiveService.swift',
    '''        - copy_to_clipboard and search_docs as appropriate.\n\n        For calendar/reminder clock times''',
    '''        - copy_to_clipboard and search_docs as appropriate.\n\n        PERSONAL/PROJECT KNOWLEDGE: if the user asks for details about Project JARVIS, its goals,\n        architecture, or personal facts about the user that are not already present in memories,\n        call search_docs before saying you do not know. The user may have imported documents such\n        as \"JARVIS - Identidade e Objetivo\" and \"Perfil do Usuário\". Never invent missing personal\n        facts; if the imported profile does not contain the answer, say so briefly.\n\n        For calendar/reminder clock times'''
)

replace(
    'OpenVision/Services/Documents/DocumentSearchTool.swift',
    '''    let description = \"Work with the user's imported documents (manuals, recipes, guides, instructions). Actions: 'search' (needs query — return the most relevant passages; use whenever the user asks about their documents), 'list' (name the imported documents), 'focus' (needs query naming the document — the user wants to work with one document, e.g. 'open my router manual'; its content will then be checked first for every question), 'unfocus' (the user is done with the document, e.g. 'close the document').\"\n''',
    '''    let description = \"Work with the user's imported documents (manuals, recipes, guides, instructions, Project JARVIS identity/goals, and user-profile facts). Actions: 'search' (needs query — return the most relevant passages; use whenever the user asks about their documents or asks personal/project questions that may be documented), 'list' (name the imported documents), 'focus' (needs query naming the document — the user wants to work with one document, e.g. 'open my router manual'; its content will then be checked first for every question), 'unfocus' (the user is done with the document, e.g. 'close the document').\"\n'''
)

# 7) Build number + notes.
replace('project.yml', '    CURRENT_PROJECT_VERSION: "16"\n', '    CURRENT_PROJECT_VERSION: "17"\n')

notes = Path('JARVIS_BUILD_NOTES.md')
notes_text = notes.read_text()
header = '# Projeto JARVIS build notes\n\n'
assert notes_text.startswith(header)
b17 = '''## Build 17\n\n- Reworked interruption around the underlying acoustic-echo problem instead of adding more transcript heuristics.\n- Phone route now uses AVAudioSession voiceChat plus AVAudioEngine voice processing (AEC) on the built-in iPhone microphone.\n- Removed the unsafe \"latest Jarvis anywhere\" barge-in heuristic that could interpret JARVIS saying its own name as a new user command and cause feedback/crash loops.\n- Barge-in follow-ups again require a deliberate phrase starting with \"Jarvis\" / the wake phrase; \"pare Jarvis\" is also supported at utterance start.\n- Diagnostics reports whether iPhone-mic voice processing/AEC was enabled or unavailable.\n- My Documents now prefers Apple's Portuguese sentence embedding (English fallback) for pt-BR JARVIS/profile documents.\n- Gemini is instructed to search imported Project JARVIS/user-profile documents before claiming it does not know documented project or personal facts.\n- App build number is 17.\n\n'''
notes.write_text(header + b17 + notes_text[len(header):])

# Remove one-shot helper files before committing the real patch.
Path('.github/workflows/apply-build17-echo-fix.yml').unlink(missing_ok=True)
Path('scripts/apply_build17.py').unlink(missing_ok=True)
