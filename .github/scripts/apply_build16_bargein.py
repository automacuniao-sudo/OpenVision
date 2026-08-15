from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text()
    if old not in text:
        raise SystemExit(f"Expected snippet not found in {path}")
    p.write_text(text.replace(old, new, 1))


voice = "OpenVision/Services/Voice/VoiceCommandService.swift"

old_branch = '''            if allowInterrupt, interruptPrefixAtStart(transcription) != nil {
                // During an active reply accept either the configured wake phrase OR the shorter
                // assistant name ("Jarvis"). This gives a natural barge-in: "Jarvis, pare" or
                // "Jarvis, e quando ele voltou ao Santos?" without waiting for the reply to finish.
                let command = extractCommandAfterInterruptPrefix(transcription)
                print("[VoiceCommand] JARVIS barge-in detected: '\\(command)'")

                // Stop output/model generation immediately. Keep this recognizer task alive: once
                // state becomes .listening, later partials of the SAME utterance keep building the
                // follow-up instead of making the user repeat it.
                onInterruption?()
                state = .listening
                currentTranscription = command
                hasSpokenThisTurn = !command.isEmpty
                resetSilenceTimer()

                if result.isFinal && !command.isEmpty {
                    print("[VoiceCommand] Barge-in result final, processing command immediately")
                    handleCommandComplete(command)
                }
                return
            }
'''
new_branch = '''            if allowInterrupt,
               let command = recentInterruptCommand(in: transcription),
               !command.isEmpty {
                // While JARVIS speaks, Apple's recognizer also hears the speaker output. The live
                // transcript therefore often starts with JARVIS' own sentence, with the user's
                // "Jarvis, ..." appended later. Detect the MOST RECENT wake/name marker instead of
                // requiring it at character zero.
                print("[VoiceCommand] JARVIS barge-in detected: '\\(command)'")
                DiagnosticLogger.shared.log("Voice", "Barge-in follow-up detected: \\(command)")

                onInterruption?()
                state = .listening
                currentTranscription = command
                hasSpokenThisTurn = true
                resetSilenceTimer()

                if result.isFinal {
                    print("[VoiceCommand] Barge-in result final, processing command immediately")
                    handleCommandComplete(command)
                }
                return
            }
'''
replace_once(voice, old_branch, new_branch)

old_stop = '''    private func isStopPhrase(_ text: String) -> Bool {
        // Require a JARVIS/wake prefix so the assistant's own Portuguese audio cannot false-trigger
        // on common words such as "para". Users can say "Jarvis, pare", "Ok Jarvis, silêncio", etc.
        guard interruptPrefixAtStart(text) != nil else { return false }
        let lower = text.lowercased()
        if lower.contains("video") || lower.contains("stream") { return false }
        let stopWords = [
            "stop", "be quiet", "shut up", "silence", "quiet", "enough", "cancel",
            "pare", "parar", "silêncio", "silencio", "cala a boca", "fica quieto", "chega", "cancela", "cancelar"
        ]
        return stopWords.contains { lower.contains($0) }
    }
'''
new_stop = '''    private func isStopPhrase(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = String(lower.suffix(100))
        if tail.contains("video") || tail.contains("stream") { return false }

        // Also accept the natural Portuguese order "pare Jarvis". Restrict these reversed forms
        // to the recent tail so ordinary words from the assistant's own echoed speech do not stop it.
        let reversedStopPhrases = [
            "pare jarvis", "para jarvis", "parar jarvis", "silêncio jarvis", "silencio jarvis",
            "chega jarvis", "cancela jarvis", "cancelar jarvis", "stop jarvis"
        ]
        if reversedStopPhrases.contains(where: { tail.contains($0) }) {
            DiagnosticLogger.shared.log("Voice", "Barge-in stop detected (stop-before-Jarvis)")
            return true
        }

        // Normal order: "Jarvis, pare" / "Ok Jarvis, silêncio". Use the latest marker because
        // the SFSpeech transcript may already contain several seconds of the assistant's own audio.
        guard let command = recentInterruptCommand(in: text)?.lowercased() else { return false }
        let stopWords = [
            "stop", "be quiet", "shut up", "silence", "quiet", "enough", "cancel",
            "pare", "parar", "silêncio", "silencio", "cala a boca", "fica quieto", "chega", "cancela", "cancelar"
        ]
        let matched = stopWords.contains { command == $0 || command.hasPrefix($0 + " ") }
        if matched { DiagnosticLogger.shared.log("Voice", "Barge-in stop detected (Jarvis-before-stop)") }
        return matched
    }

    /// Extract text after the most recent JARVIS/wake marker in the tail of an accumulating
    /// SFSpeech transcript. During playback that transcript includes speaker echo, so looking only
    /// at the beginning makes real interruptions invisible.
    private func recentInterruptCommand(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let lowerNSString = lower as NSString
        let originalNSString = trimmed as NSString
        let prefixes = [
            wakeWord.lowercased(),
            "ok jarvis", "okay jarvis", "o.k. jarvis", "o k jarvis", "hey jarvis", "jarvis",
            "ok vision", "okay vision", "o.k. vision", "o k vision", "hey vision", "hi vision"
        ]

        var bestLocation = NSNotFound
        var bestLength = 0
        for prefix in prefixes where !prefix.isEmpty {
            let range = lowerNSString.range(of: prefix, options: .backwards)
            if range.location != NSNotFound && (bestLocation == NSNotFound || range.location > bestLocation) {
                bestLocation = range.location
                bestLength = range.length
            }
        }
        guard bestLocation != NSNotFound else { return nil }

        // A deliberate interrupt should be recent. This rejects an old "Jarvis" that may have
        // appeared much earlier in echoed assistant speech.
        guard lowerNSString.length - bestLocation <= 120 else { return nil }
        let end = bestLocation + bestLength
        guard end <= originalNSString.length else { return nil }

        return originalNSString.substring(from: end)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!?-–—"))
    }
'''
replace_once(voice, old_stop, new_stop)

vm = "OpenVision/Views/VoiceAgent/VoiceAgentViewModel.swift"
old_vm = '''            return self.ttsService.isSpeaking
                || KokoroTTSService.shared.isSpeaking
                || GeminiLiveService.shared.isModelSpeaking
                || self.audioPlayback.isPlaying
'''
new_vm = '''            return self.ttsService.isSpeaking
                || KokoroTTSService.shared.isSpeaking
                || GeminiLiveService.shared.isModelSpeaking
                || GeminiLiveService.shared.isProcessing
                || self.audioPlayback.isPlaying
'''
replace_once(vm, old_vm, new_vm)

replace_once("project.yml", '    CURRENT_PROJECT_VERSION: "15"', '    CURRENT_PROJECT_VERSION: "16"')

notes = Path("JARVIS_BUILD_NOTES.md")
text = notes.read_text()
header = '''# Projeto JARVIS build notes\n\n'''
if not text.startswith(header):
    raise SystemExit("Unexpected build notes header")
build16 = '''## Build 16\n\n- Barge-in hotfix based on on-device diagnostics.\n- Interruption no longer requires "Jarvis" to be at character zero of Apple's accumulating STT transcript; the latest recent JARVIS marker is used, so speaker echo before the user's phrase does not hide the command.\n- Both "Jarvis, pare" and the natural reversed order "pare Jarvis" are accepted.\n- Follow-ups such as "Jarvis, agora fale sobre X" interrupt the current Gemini native-audio reply.\n- Interruption is also allowed while Gemini is processing, before the first PCM chunk arrives.\n- App build number is 16.\n\n'''
notes.write_text(header + build16 + text[len(header):])
