from pathlib import Path


def replace(path, old, new):
    p = Path(path)
    text = p.read_text()
    if old not in text:
        raise SystemExit(f'Pattern not found in {path}: {old[:160]!r}')
    p.write_text(text.replace(old, new, 1))

# 1) Phone hands-free mode: use videoChat (speakerphone-oriented) and always assert the speaker
# when the active route is built-in. Apple's docs note videoChat automatically favors speaker and
# is designed for two-way hands-free voice. Voice processing remains enabled by VoiceCommandService.
replace(
    'OpenVision/Services/Audio/AudioSessionManager.swift',
    '''        try audioSession.setCategory(\n            .playAndRecord,\n            mode: .voiceChat,\n            options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP]\n        )\n''',
    '''        try audioSession.setCategory(\n            .playAndRecord,\n            mode: .videoChat,\n            options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP]\n        )\n'''
)

replace(
    'OpenVision/Services/Audio/AudioSessionManager.swift',
    '''        if outputs.contains(where: { $0.portType == .builtInReceiver }) {\n            do {\n                try audioSession.overrideOutputAudioPort(.speaker)\n                DiagnosticLogger.shared.log("Audio", "Forced loudspeaker route: \\(currentRouteDescription)")\n            } catch {\n                DiagnosticLogger.shared.log("Audio", "Speaker override failed: \\(error.localizedDescription)")\n            }\n        }\n''',
    '''        // Do not rely only on currentRoute reporting `.builtInSpeaker`. Voice-processing /\n        // playAndRecord renegotiation can leave the session on a low speakerphone gain path while\n        // the route label already says Speaker. Re-asserting the speaker override is cheap and\n        // deterministic for the built-in phone route; Apple documents that this explicitly routes\n        // playAndRecord to the built-in speaker + mic until the next route change.\n        do {\n            try audioSession.overrideOutputAudioPort(.speaker)\n            DiagnosticLogger.shared.log(\n                "Audio",\n                "Forced loudspeaker route: \\(currentRouteDescription) systemVolume=\\(Int(audioSession.outputVolume * 100))%"\n            )\n        } catch {\n            DiagnosticLogger.shared.log("Audio", "Speaker override failed: \\(error.localizedDescription)")\n        }\n'''
)

# Add a built-in output helper used to avoid needless audio-session teardown on wake.
replace(
    'OpenVision/Services/Audio/AudioSessionManager.swift',
    '''    /// Check if using built-in mic\n    var isUsingBuiltInMic: Bool {\n        audioSession.currentRoute.inputs.contains { port in\n            port.portType == .builtInMic\n        }\n    }\n''',
    '''    /// Check if using built-in mic\n    var isUsingBuiltInMic: Bool {\n        audioSession.currentRoute.inputs.contains { port in\n            port.portType == .builtInMic\n        }\n    }\n\n    /// Check if output is one of the iPhone's built-in outputs (receiver or loud speaker).\n    var isUsingBuiltInOutput: Bool {\n        let outputs = audioSession.currentRoute.outputs\n        return !outputs.isEmpty && outputs.allSatisfy {\n            $0.portType == .builtInReceiver || $0.portType == .builtInSpeaker\n        }\n    }\n\n    /// Read-only system volume for diagnostics. iOS intentionally allows only the user to change it.\n    var systemOutputVolume: Float { audioSession.outputVolume }\n'''
)

# 2) Avoid reconfiguring/stopping the already-correct phone listener immediately after the wake
# chime. That churn could cut the chime and also renegotiate output back onto the low receiver path.
replace(
    'OpenVision/Views/VoiceAgent/VoiceAgentViewModel.swift',
    '''        if settingsManager.settings.preferGlassesMic, glassesManager.isRegistered,\n           !glassesManager.isStreaming,   // HFP is deaf while the camera streams — reconfigure to phone\n           AudioSessionManager.shared.isBluetoothHFPActive, voiceCommandService.isListening {\n            return\n        }\n        let wasListening = voiceCommandService.isListening\n''',
    '''        if settingsManager.settings.preferGlassesMic, glassesManager.isRegistered,\n           !glassesManager.isStreaming,   // HFP is deaf while the camera streams — reconfigure to phone\n           AudioSessionManager.shared.isBluetoothHFPActive, voiceCommandService.isListening {\n            return\n        }\n\n        // Phone-only wake path: if the persistent listener is already using the built-in mic/output,\n        // do NOT stop/restart the audio engine at the exact moment the acknowledgement chime starts.\n        // Just re-assert speakerphone routing. This preserves the chime and avoids the low-volume\n        // receiver renegotiation observed after saying the wake phrase.\n        if voiceCommandService.isListening,\n           AudioSessionManager.shared.isUsingBuiltInMic,\n           AudioSessionManager.shared.isUsingBuiltInOutput {\n            AudioSessionManager.shared.enforcePhoneSpeakerRoute()\n            DiagnosticLogger.shared.log("Audio", "Wake session reused existing phone audio route")\n            return\n        }\n\n        let wasListening = voiceCommandService.isListening\n'''
)

# 3) Chime: force route BEFORE playback and explicitly set player gain to 1.0. This is app-level
# gain, not the user's system volume. Add richer diagnostics for asset duration + system volume.
replace(
    'OpenVision/Services/Audio/SoundService.swift',
    '''        if let wakeURL {\n            wakeWordPlayer = try? AVAudioPlayer(contentsOf: wakeURL)\n            wakeWordPlayer?.prepareToPlay()\n            DiagnosticLogger.shared.log("Audio", "Wake chime asset ready")\n''',
    '''        if let wakeURL {\n            wakeWordPlayer = try? AVAudioPlayer(contentsOf: wakeURL)\n            wakeWordPlayer?.volume = 1.0\n            wakeWordPlayer?.prepareToPlay()\n            let durationMs = Int((wakeWordPlayer?.duration ?? 0) * 1000)\n            DiagnosticLogger.shared.log("Audio", "Wake chime asset ready duration=\\(durationMs)ms")\n'''
)

replace(
    'OpenVision/Services/Audio/SoundService.swift',
    '''        if let player = wakeWordPlayer {\n            player.currentTime = 0\n            let started = player.play()\n            DiagnosticLogger.shared.log("Audio", "Wake chime play=\\(started) route=\\(AudioSessionManager.shared.currentRouteDescription)")\n''',
    '''        if let player = wakeWordPlayer {\n            // The wake listener uses playAndRecord. Re-assert the phone loudspeaker immediately\n            // before the acknowledgement sound so a stale receiver/voice route cannot swallow it.\n            if AudioSessionManager.shared.isUsingBuiltInMic {\n                AudioSessionManager.shared.enforcePhoneSpeakerRoute()\n            }\n            player.volume = 1.0\n            player.currentTime = 0\n            let started = player.play()\n            DiagnosticLogger.shared.log(\n                "Audio",\n                "Wake chime play=\\(started) route=\\(AudioSessionManager.shared.currentRouteDescription) systemVolume=\\(Int(AudioSessionManager.shared.systemOutputVolume * 100))%"\n            )\n'''
)

# 4) Gemini/native PCM playback: assert the speaker after AVAudioEngine starts and once at the
# beginning of every newly-drained response queue. No per-chunk route churn.
replace(
    'OpenVision/Services/Audio/AudioPlaybackService.swift',
    '''        try engine.start()\n        print("[AudioPlayback] Engine started")\n        DiagnosticLogger.shared.log("Audio", "Playback engine started format=\\(outputFormat.sampleRate)Hz/\\(outputFormat.channelCount)ch")\n''',
    '''        try engine.start()\n        if AudioSessionManager.shared.isUsingBuiltInMic {\n            AudioSessionManager.shared.enforcePhoneSpeakerRoute()\n        }\n        print("[AudioPlayback] Engine started")\n        DiagnosticLogger.shared.log(\n            "Audio",\n            "Playback engine started format=\\(outputFormat.sampleRate)Hz/\\(outputFormat.channelCount)ch route=\\(AudioSessionManager.shared.currentRouteDescription) systemVolume=\\(Int(AudioSessionManager.shared.systemOutputVolume * 100))%"\n        )\n'''
)

replace(
    'OpenVision/Services/Audio/AudioPlaybackService.swift',
    '''        // Schedule and play. Track queue depth ourselves: AVAudioPlayerNode.isPlaying\n        // describes the node state, not whether any buffers remain queued.\n        let generation = playbackGeneration\n        scheduledBufferCount += 1\n''',
    '''        // At the start of a fresh reply, re-assert speakerphone routing. Route changes caused\n        // by voice processing/background transitions can happen between responses.\n        if scheduledBufferCount == 0, AudioSessionManager.shared.isUsingBuiltInMic {\n            AudioSessionManager.shared.enforcePhoneSpeakerRoute()\n        }\n\n        // Schedule and play. Track queue depth ourselves: AVAudioPlayerNode.isPlaying\n        // describes the node state, not whether any buffers remain queued.\n        let generation = playbackGeneration\n        scheduledBufferCount += 1\n'''
)

# 5) Remove the dead duplicate activation player in VoiceCommandService. There is no
# activation_chime.wav resource; SoundService is the single acknowledgement-sound owner.
p = Path('OpenVision/Services/Voice/VoiceCommandService.swift')
text = p.read_text()
text = text.replace('''    // MARK: - Audio Feedback\n\n    private var activationSound: AVAudioPlayer?\n\n''', '')
text = text.replace('''    private init() {\n        setupActivationSound()\n    }\n''', '''    private init() {}\n''')
text = text.replace('''        // Play activation sound\n        if playActivationSound {\n            playActivation()\n        }\n\n''', '')
start_marker = '''    // MARK: - Audio Feedback\n\n    /// Setup activation sound\n'''
if start_marker in text:
    a = text.index(start_marker)
    b = text.index('\n}\n\n// MARK: - Errors', a)
    text = text[:a] + text[b:]
p.write_text(text)

# 6) Build number + notes.
replace('project.yml', '    CURRENT_PROJECT_VERSION: "19"\n', '    CURRENT_PROJECT_VERSION: "20"\n')

notes = Path('JARVIS_BUILD_NOTES.md')
notes_text = notes.read_text()
header = '# Projeto JARVIS build notes\n\n'
assert notes_text.startswith(header)
b20 = '''## Build 20\n\n- Fixed the missing wake acknowledgement sound by eliminating audio-session churn immediately after wake detection and making SoundService the single chime owner.\n- Wake chime now re-asserts the built-in loudspeaker before playback, uses full app-level player gain, and logs asset duration, route, and system volume.\n- Phone hands-free audio uses AVAudioSession videoChat mode plus explicit speaker override while retaining AVAudioEngine voice processing/AEC.\n- Speaker override is now re-asserted even when iOS already labels the route as built-in Speaker, because route renegotiation can leave a low voice-output path behind.\n- Gemini PCM playback re-asserts the phone loudspeaker after its playback engine starts and at the beginning of each fresh reply.\n- Added richer audio diagnostics (route + read-only system volume) to distinguish routing problems from the user's hardware volume setting.\n- Removed the obsolete VoiceCommandService activation_chime.wav player; that resource does not exist and duplicated SoundService behavior.\n- App build number is 20.\n\n'''
notes.write_text(header + b20 + notes_text[len(header):])

# Remove helper artifacts before committing the real patch.
Path('.github/workflows/apply-build20-audio-fix.yml').unlink(missing_ok=True)
Path('scripts/apply_build20_audio_fix.py').unlink(missing_ok=True)
