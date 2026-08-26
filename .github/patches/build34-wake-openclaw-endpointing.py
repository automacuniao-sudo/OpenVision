from pathlib import Path

root = Path('.')

# 1) Gemini wake handoff: Apple Speech going idle is expected while direct PCM takes ownership.
vm = root / 'JARVIS/Views/VoiceAgent/VoiceAgentViewModel.swift'
text = vm.read_text()
old = '''            // A real conversation end is the recognizer going idle *while we were listening*
            // for the user (silence timeout). An .idle in any other state (.connecting startup,
            // .thinking/.toolRunning command processing, .speaking a reply) is a transient from
            // our own stop/restart — e.g. the camera capture restarts the recognizer mid-command
            // — and must NOT tear the session down. (This is what left the wake word dead after a
            // face/camera command: the restart flipped to .idle during .thinking and killed the
            // session, so the post-reply audio rebuild never ran.)
            if isSessionActive && agentState == .listening {
'''
new = '''            // Direct Gemini deliberately stops Apple Speech when the realtime PCM stream takes
            // ownership of the microphone. That stop emits `.idle`; it is a microphone handoff,
            // NOT the end of the conversation. Build 33 still let the legacy idle observer race
            // with startDirectGeminiVoiceMode(), which disconnected Gemini milliseconds after a
            // successful wake connection. Suppression is set before stopListening(), so it is the
            // authoritative handoff guard even before isDirectGeminiVoiceMode flips true.
            if voiceCommandService.isWakeRecoverySuppressed || isDirectGeminiVoiceMode {
                DiagnosticLogger.shared.log("Voice", "Ignored recognizer idle during direct Gemini mic handoff")
                return
            }

            // A real conversation end is the recognizer going idle *while we were listening*
            // for the user (silence timeout). An .idle in any other state (.connecting startup,
            // .thinking/.toolRunning command processing, .speaking a reply) is a transient from
            // our own stop/restart — e.g. the camera capture restarts the recognizer mid-command
            // — and must NOT tear the session down.
            if isSessionActive && agentState == .listening {
'''
if old not in text:
    raise SystemExit('VoiceAgent idle teardown anchor not found')
text = text.replace(old, new, 1)
vm.write_text(text)

# 2) Conversation STT: only treat JARVIS as a removable wake prefix at the beginning.
voice = root / 'JARVIS/Services/Voice/VoiceCommandService.swift'
text = voice.read_text()
old = '''        case .listening, .conversationMode:
            var command = transcription
            for phrase in jarvisWakeVariants {
                if let range = command.lowercased().range(of: phrase) {
                    command = String(command[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                    break
                }
            }

            currentTranscription = command
'''
new = '''        case .listening, .conversationMode:
            // The wake marker is removable only when it is actually a PREFIX. Build 33 searched
            // anywhere in the sentence, so a natural phrase such as “Você está me ouvindo Jarvis?”
            // became an empty command and remained stuck on Listening forever. Mid/end-sentence
            // mentions of Jarvis are ordinary user content and must be preserved.
            var command = transcription.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowerCommand = command.lowercased()
            for phrase in jarvisWakeVariants where lowerCommand.hasPrefix(phrase) {
                command = String(command.dropFirst(phrase.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!?-–—"))
                break
            }

            currentTranscription = command
'''
if old not in text:
    raise SystemExit('VoiceCommand conversation stripping anchor not found')
text = text.replace(old, new, 1)

# 3) Hybrid endpointing: VAD is primary, but never the only path to committing a turn.
old = '''    /// Fallback endpointing only. When acoustic VAD is healthy, speechEnd owns turn commit.
    private func resetSilenceTimer() {
        guard !speechDetector.isAvailable else { return }
        silenceTimer?.invalidate()
        let timeout = TurnEndpointing.silenceTimeout(for: currentTranscription)
        silenceTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.handleSilenceTimeout()
            }
        }
    }
'''
new = '''    /// Hybrid endpointing. Acoustic VAD is the fast primary signal, but it must never be the
    /// only path to committing a turn: room noise, Bluetooth routes, or a missed Silero speechEnd
    /// can otherwise leave Conversation Mode on Listening forever. Every fresh STT partial arms a
    /// conservative lexical watchdog; a real VAD speechEnd replaces it with the shorter VAD grace.
    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        let lexicalTimeout = TurnEndpointing.silenceTimeout(for: currentTranscription)
        let timeout = speechDetector.isAvailable ? max(1.25, lexicalTimeout) : lexicalTimeout
        silenceTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.speechDetector.isAvailable {
                    DiagnosticLogger.shared.log(
                        "VAD",
                        "speechEnd fallback timer committed turn after \\(Int(timeout * 1000))ms"
                    )
                }
                self.handleSilenceTimeout()
            }
        }
    }
'''
if old not in text:
    raise SystemExit('VoiceCommand endpointing anchor not found')
text = text.replace(old, new, 1)
voice.write_text(text)

# 4) Version bump.
proj = root / 'project.yml'
text = proj.read_text()
if 'CURRENT_PROJECT_VERSION: "33"' not in text:
    raise SystemExit('Build 33 project version anchor not found')
proj.write_text(text.replace('CURRENT_PROJECT_VERSION: "33"', 'CURRENT_PROJECT_VERSION: "34"', 1))

notes = root / 'JARVIS_BUILD_NOTES.md'
with notes.open('a') as f:
    f.write('''\n\n## Build 34 — Wake handoff + OpenClaw turn commit\n\n- Fixes a Build 33 race where the intentional Apple Speech -> Gemini PCM microphone handoff emitted `.idle` and the legacy observer immediately disconnected the just-connected Gemini Live session.\n- In Conversation Mode, JARVIS/wake words are stripped only when they are at the beginning of an utterance. Phrases ending in “Jarvis” no longer collapse to an empty command.\n- VAD is now primary but not exclusive: every STT partial arms a conservative endpoint fallback, preventing OpenClaw/text backends from staying on Listening forever when Silero misses `speechEnd`.\n- Search/grounding behavior is intentionally unchanged for the next dedicated research pass.\n''')

print('Build 34 patch applied successfully')
