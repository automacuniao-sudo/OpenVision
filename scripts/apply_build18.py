from pathlib import Path


def replace(path, old, new):
    p = Path(path)
    text = p.read_text()
    if old not in text:
        raise SystemExit(f'Pattern not found in {path}: {old[:140]!r}')
    p.write_text(text.replace(old, new, 1))

# 1) Gemini Live: enable native Google Search alongside custom iPhone tools.
replace(
    'OpenVision/Services/GeminiLive/GeminiLiveService.swift',
    '''    private func buildToolDeclarations() -> [[String: Any]] {\n        [["functionDeclarations": NativeToolRegistry.shared.geminiDeclarations]]\n    }\n''',
    '''    private func buildToolDeclarations() -> [[String: Any]] {\n        // Gemini 3.1 Flash Live supports combining built-in Google Search grounding with our\n        // synchronous native function tools in the SAME Live session. This is what lets JARVIS\n        // answer time-sensitive questions (sports schedules, current news, prices, etc.) instead\n        // of falling back to stale model knowledge or claiming it cannot browse.\n        [\n            ["googleSearch": [:] as [String: Any]],\n            ["functionDeclarations": NativeToolRegistry.shared.geminiDeclarations]\n        ]\n    }\n'''
)

replace(
    'OpenVision/Services/GeminiLive/GeminiLiveService.swift',
    '''        IMPORTANT: when the user asks JARVIS to perform an iPhone action that has a matching tool, CALL THE TOOL instead of merely explaining how to do it.\n\n        Available on-device actions include:\n''',
    '''        IMPORTANT: when the user asks JARVIS to perform an iPhone action that has a matching tool, CALL THE TOOL instead of merely explaining how to do it.\n\n        INTERNET / CURRENT INFORMATION: Google Search grounding is available in this live session. Use it whenever the user asks to search/pesquisar na internet, or whenever the answer depends on current or time-sensitive information such as sports schedules/results, news, weather, prices, releases, current office-holders, or recent events. Do not say that you cannot browse when Google Search is available. For example, a question such as "qual é o próximo jogo do Corinthians?" should be grounded with Google Search before answering.\n\n        Available on-device actions include:\n'''
)

replace(
    'OpenVision/Services/GeminiLive/GeminiLiveService.swift',
    '''        DiagnosticLogger.shared.log("Gemini", "Sending session setup: AUDIO voice=\\(voiceName) + pt-BR JARVIS instruction")\n''',
    '''        DiagnosticLogger.shared.log("Gemini", "Sending session setup: AUDIO voice=\\(voiceName) + pt-BR JARVIS + Google Search")\n'''
)

# 2) Make sound assets robust whether Xcode flattens Resources or preserves the Sounds directory.
replace(
    'OpenVision/Services/Audio/SoundService.swift',
    '''        let wakeURL = Bundle.main.url(forResource: "wake_activation", withExtension: "mp3")\n            ?? Bundle.main.url(forResource: "wake_word_ding", withExtension: "mp3")\n        if let wakeURL {\n            wakeWordPlayer = try? AVAudioPlayer(contentsOf: wakeURL)\n            wakeWordPlayer?.prepareToPlay()\n        }\n\n        // Thinking loop sound (stays a system sound — ambient, phone-side is fine)\n        if let url = Bundle.main.url(forResource: "thinking_loop", withExtension: "mp3") {\n''',
    '''        let wakeURL = Bundle.main.url(forResource: "wake_activation", withExtension: "mp3")\n            ?? Bundle.main.url(forResource: "wake_activation", withExtension: "mp3", subdirectory: "Sounds")\n            ?? Bundle.main.url(forResource: "wake_word_ding", withExtension: "mp3")\n            ?? Bundle.main.url(forResource: "wake_word_ding", withExtension: "mp3", subdirectory: "Sounds")\n        if let wakeURL {\n            wakeWordPlayer = try? AVAudioPlayer(contentsOf: wakeURL)\n            wakeWordPlayer?.prepareToPlay()\n            DiagnosticLogger.shared.log("Audio", "Wake chime asset ready")\n        } else {\n            DiagnosticLogger.shared.log("Audio", "ERROR: wake chime asset not found")\n        }\n\n        // Thinking loop sound (stays a system sound — ambient, phone-side is fine)\n        if let url = Bundle.main.url(forResource: "thinking_loop", withExtension: "mp3")\n            ?? Bundle.main.url(forResource: "thinking_loop", withExtension: "mp3", subdirectory: "Sounds") {\n'''
)

replace(
    'OpenVision/Services/Audio/SoundService.swift',
    '''    // MARK: - Wake Word Sound\n\n    func playWakeWordSound() {\n        guard soundEnabled else { return }\n''',
    '''    // MARK: - Wake Word Sound\n\n    /// Preload the acknowledgement sound at app startup so the first wake word does not pay the\n    /// AVAudioPlayer setup cost (or silently fail due to a resource-path issue).\n    func prepare() {\n        ensureSoundsReady()\n    }\n\n    func playWakeWordSound() {\n        guard soundEnabled else {\n            DiagnosticLogger.shared.log("Audio", "Wake chime skipped: disabled in settings")\n            return\n        }\n'''
)

replace(
    'OpenVision/Services/Audio/SoundService.swift',
    '''        if let player = wakeWordPlayer {\n            player.currentTime = 0\n            player.play()\n        } else if wakeWordSoundID != 0 {\n''',
    '''        if let player = wakeWordPlayer {\n            player.currentTime = 0\n            let started = player.play()\n            DiagnosticLogger.shared.log("Audio", "Wake chime play=\\(started) route=\\(AudioSessionManager.shared.currentRouteDescription)")\n        } else if wakeWordSoundID != 0 {\n'''
)

# 3) Phone route: voice processing can renegotiate the route after initial configuration. Explicitly
# select the built-in mic and reinforce the speaker after the session settles.
replace(
    'OpenVision/Services/Audio/AudioSessionManager.swift',
    '''        try audioSession.setActive(true)\n        // If still routed to the quiet earpiece (carried over from a glasses/voiceChat config),\n        // force the loud speaker — but leave AirPods / headphones alone if they're connected.\n        if audioSession.currentRoute.outputs.contains(where: { $0.portType == .builtInReceiver }) {\n            try? audioSession.overrideOutputAudioPort(.speaker)\n        }\n        currentMode = .voiceChat\n        print("[AudioSession] Configured for phone (built-in mic + loud speaker)")\n    }\n''',
    '''        try audioSession.setActive(true)\n\n        // `.allowBluetoothHFP` is needed for future route flexibility, but when the user selected\n        // the PHONE mic we must not let an available HFP device silently become the input.\n        if let builtInMic = audioSession.availableInputs?.first(where: { $0.portType == .builtInMic }) {\n            try? audioSession.setPreferredInput(builtInMic)\n        }\n\n        enforcePhoneSpeakerRoute()\n        currentMode = .voiceChat\n        DiagnosticLogger.shared.log("Audio", "Phone audio configured: \\(currentRouteDescription)")\n        print("[AudioSession] Configured for phone (built-in mic + loud speaker)")\n\n        // Enabling voice processing / starting AVAudioEngine may renegotiate playAndRecord back to\n        // the receiver a moment later. Reinforce only when the output is still an iPhone built-in\n        // route; never steal audio from headphones/Bluetooth.\n        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in\n            self?.enforcePhoneSpeakerRoute()\n        }\n    }\n\n    /// Force the loud iPhone speaker only when output is currently a built-in receiver/speaker.\n    /// External Bluetooth/headphone routes are intentionally left untouched.\n    func enforcePhoneSpeakerRoute() {\n        let outputs = audioSession.currentRoute.outputs\n        let hasExternalOutput = outputs.contains { output in\n            output.portType != .builtInReceiver && output.portType != .builtInSpeaker\n        }\n        guard !hasExternalOutput else { return }\n        if outputs.contains(where: { $0.portType == .builtInReceiver }) {\n            do {\n                try audioSession.overrideOutputAudioPort(.speaker)\n                DiagnosticLogger.shared.log("Audio", "Forced loudspeaker route: \\(currentRouteDescription)")\n            } catch {\n                DiagnosticLogger.shared.log("Audio", "Speaker override failed: \\(error.localizedDescription)")\n            }\n        }\n    }\n'''
)

# After AEC is enabled, immediately re-check speaker routing because VoiceProcessingIO can change it.
replace(
    'OpenVision/Services/Voice/VoiceCommandService.swift',
    '''                try inputNode.setVoiceProcessingEnabled(true)\n                DiagnosticLogger.shared.log("Audio", "Voice processing enabled (AEC) on iPhone mic")\n''',
    '''                try inputNode.setVoiceProcessingEnabled(true)\n                DiagnosticLogger.shared.log("Audio", "Voice processing enabled (AEC) on iPhone mic")\n                AudioSessionManager.shared.enforcePhoneSpeakerRoute()\n'''
)

# 4) Prefer on-device Apple speech recognition when pt-BR assets are available. This removes a\n# network dependency from wake/barge-in and is more appropriate for a background audio session.
replace(
    'OpenVision/Services/Voice/VoiceCommandService.swift',
    '''        request.shouldReportPartialResults = true\n        // Short-phrase search while idle for the wake word; full dictation once activated.\n''',
    '''        request.shouldReportPartialResults = true\n        if speechRecognizer?.supportsOnDeviceRecognition == true {\n            request.requiresOnDeviceRecognition = true\n        }\n        // Short-phrase search while idle for the wake word; full dictation once activated.\n'''
)

# 5) Voice runtime must not be tied to whether the Voice tab is visible. Settings/history/background\n# should not stop the always-on wake listener after the user has launched the app.
replace(
    'OpenVision/Views/VoiceAgent/VoiceAgentViewModel.swift',
    '''    func onDisappear() {\n        voiceCommandService.stopListening()\n    }\n''',
    '''    func onDisappear() {\n        // Deliberately keep the wake-word audio runtime alive when the user leaves the Voice tab\n        // or backgrounds the app. UIBackgroundModes=audio is already enabled; tying recognition\n        // to this SwiftUI view made JARVIS stop being hands-free as soon as the tab disappeared.\n        DiagnosticLogger.shared.log("Voice", "Voice view disappeared; keeping wake listener alive")\n    }\n'''
)

# 6) App lifecycle diagnostics + proactive sound preload. We do NOT pretend this can cold-launch a\n# terminated iOS app: it only keeps/recover the runtime while iOS still has our audio app alive.
replace(
    'OpenVision/App/OpenVisionApp.swift',
    '''struct OpenVisionApp: App {\n    // MARK: - State Objects\n''',
    '''struct OpenVisionApp: App {\n    @Environment(\\.scenePhase) private var scenePhase\n\n    // MARK: - State Objects\n'''
)

replace(
    'OpenVision/App/OpenVisionApp.swift',
    '''        // Show timer/alarm notifications even when the app is in the foreground.\n        NotificationForegroundPresenter.shared.register()\n''',
    '''        // Show timer/alarm notifications even when the app is in the foreground.\n        NotificationForegroundPresenter.shared.register()\n        SoundService.shared.prepare()\n'''
)

replace(
    'OpenVision/App/OpenVisionApp.swift',
    '''            .onOpenURL { url in\n                handleURL(url)\n            }\n''',
    '''            .onOpenURL { url in\n                handleURL(url)\n            }\n            .onChange(of: scenePhase) { phase in\n                DiagnosticLogger.shared.log(\n                    "App",\n                    "Scene phase=\\(phase) voiceListening=\\(VoiceCommandService.shared.isListening) route=\\(AudioSessionManager.shared.currentRouteDescription)"\n                )\n                // If iOS returned us to active after an interruption/background transition and the\n                // recognizer died, revive wake-word listening. Background audio itself keeps the\n                // already-running listener alive; this is a recovery path, not a cold-launch hack.\n                if phase == .active,\n                   SettingsManager.shared.settings.wakeWordEnabled,\n                   VoiceCommandService.shared.authorizationStatus == .authorized,\n                   !VoiceCommandService.shared.isListening {\n                    try? AudioSessionManager.shared.configureForPhone()\n                    try? VoiceCommandService.shared.startListening()\n                    DiagnosticLogger.shared.log("Voice", "Recovered wake listener on app activation")\n                }\n            }\n'''
)

# 7) Build number + notes.
replace('project.yml', '    CURRENT_PROJECT_VERSION: "17"\n', '    CURRENT_PROJECT_VERSION: "18"\n')

notes = Path('JARVIS_BUILD_NOTES.md')
text = notes.read_text()
header = '# Projeto JARVIS build notes\n\n'
assert text.startswith(header)
b18 = '''## Build 18\n\n- Enabled Gemini 3.1 Flash Live built-in Google Search grounding alongside the existing native iPhone function tools. Current/time-sensitive questions such as sports schedules can now be searched instead of being refused.\n- Added explicit prompt routing for internet/current-information requests.\n- Fixed wake-word sound asset lookup for both flattened resources and the `Sounds/` bundle directory; preloads the chime and logs whether playback actually started.\n- Hardened phone audio routing: explicitly prefers the built-in mic and re-forces the loudspeaker after voice-processing/AVAudioEngine route renegotiation.\n- Wake-word/command recognition prefers on-device Apple Speech when pt-BR on-device recognition is available.\n- Leaving the Voice tab no longer stops the wake listener; background audio can keep the already-running voice runtime alive after the app has been launched.\n- Added app scene-phase diagnostics and foreground recovery if iOS kills the recognizer during a background/audio interruption.\n- Important iOS boundary: this improves background operation while the app remains running, but a normal third-party app still cannot cold-launch itself from a custom microphone phrase after being force-quit/terminated.\n- App build number is 18.\n\n'''
notes.write_text(header + b18 + text[len(header):])

# Remove temporary patch machinery before committing final code.
Path('.github/workflows/apply-build18.yml').unlink(missing_ok=True)
Path('scripts/apply_build18.py').unlink(missing_ok=True)
