# Projeto JARVIS build notes

## Build 17

- Reworked interruption around the underlying acoustic-echo problem instead of adding more transcript heuristics.
- Phone route now uses AVAudioSession voiceChat plus AVAudioEngine voice processing (AEC) on the built-in iPhone microphone.
- Removed the unsafe "latest Jarvis anywhere" barge-in heuristic that could interpret JARVIS saying its own name as a new user command and cause feedback/crash loops.
- Barge-in follow-ups again require a deliberate phrase starting with "Jarvis" / the wake phrase; "pare Jarvis" is also supported at utterance start.
- Diagnostics reports whether iPhone-mic voice processing/AEC was enabled or unavailable.
- My Documents now prefers Apple's Portuguese sentence embedding (English fallback) for pt-BR JARVIS/profile documents.
- Gemini is instructed to search imported Project JARVIS/user-profile documents before claiming it does not know documented project or personal facts.
- App build number is 17.

## Build 16

- Barge-in hotfix based on on-device diagnostics and speaker-echo behavior.
- Interruption no longer requires "Jarvis" to be at character zero of Apple's accumulating STT transcript; the latest recent JARVIS marker is used, so speaker echo before the user's phrase does not hide the command.
- Both "Jarvis, pare" and the natural reversed order "pare Jarvis" are accepted.
- Follow-ups such as "Jarvis, agora fale sobre X" interrupt the current Gemini native-audio reply.
- Interruption is also allowed while Gemini is processing, before the first PCM chunk arrives.
- App build number is 16.

## Build 15

- Conversation polish hotfix: barge-in and reliable auto-end before deeper phone-control work.
- Gemini native audio can now be interrupted while speaking: say "Jarvis, pare" or start a follow-up with "Jarvis, ..." without waiting for the answer to finish.
- Gemini PCM playback queue is tracked explicitly; server turn completion waits for audible PCM to drain before starting the conversation auto-end timer.
- Local barge-in immediately clears queued PCM and suppresses late chunks from the interrupted response.
- Late Gemini turn-complete events no longer reopen a conversation after a full stop.
- Portuguese stop phrases are recognized.
- Diagnostics logs barge-in, discarded stale PCM, deferred turn completion, and playback-queue drain.
- App build number is 15.

## Build 14

- JARVIS now identifies itself as the user's Project JARVIS personal assistant rather than a generic Gemini assistant.
- Explicit pt-BR tool-routing instructions for iPhone actions.
- Added selectable Gemini Live native voices; default is Charon. This is separate from Apple Voice/Kokoro.
- Added `device_status` for real iPhone battery percentage, charging state, Low Power Mode, and iOS version.
- Expanded Apple Calendar integration: list today/upcoming, create, edit, and delete events through EventKit.
- Expanded Apple Reminders integration: create, list, edit, and delete incomplete reminders through EventKit.
- Improved relative-time parsing for Brazilian Portuguese (for example, "daqui a 15 minutos").
- Localized native-tool date/time confirmations to pt-BR.
- Native tool calls and success/failure states are now written to Diagnostics / Logs without logging private argument values.
- Gemini server-content parsing now processes sibling audio/transcription fields before turnComplete.
- Apple Notes remains intentionally separate: the current `note` tool stores JARVIS-internal notes only.
- App build number is 14.

## Build 13

- Added in-app Diagnostics / Logs screen for testing without Xcode or a Mac.
- Logs speech recognition, Gemini connection/turns/audio chunks, and audio playback.
- Changed Apple Speech Recognition locale from en-US to pt-BR.
- Uses dictation mode for commands after the wake word, while keeping short-phrase search for wake-word detection.
- Gemini Live system instruction now defaults replies to Brazilian Portuguese unless another language is explicitly requested.
- Fixed Voice Control > Auto-End Timeout so the configured value is actually used; Never (0) disables the app-side silence timer.
- App build number is 13.
