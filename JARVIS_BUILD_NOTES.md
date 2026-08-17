# Projeto JARVIS build notes

## Build 22

- Audio: compared the current path with the clean build-12/13 PCM path; removed the build-21 2.5x hard-limited software gain that caused clipping/"chiado". Gemini PCM is back at unity gain.
- Audio: kept AVAudioEngine voice processing/AEC and all working barge-in behavior, but configured voice-processing other-audio ducking to minimum so the separate Gemini playback engine is not heavily attenuated.
- Web search: fixed the architecture mismatch where Settings showed DuckDuckGo/Tavily while the Gemini `web_search` tool ignored that setting and called Google grounding directly. `web_search` now delegates to the existing WebSearchService: Tavily when configured, otherwise keyless DuckDuckGo.
- History: Gemini output-transcription fragments are accumulated into the complete assistant reply before persistence; normal wake-word user messages are no longer duplicated by the live-turn recorder.
- Custom Instructions: one-time starter instructions are populated automatically only when the field is empty.
- Memories: one-time Project JARVIS starter memories are populated without overwriting existing memory values; a migration marker prevents deleted/edited memories from being recreated every launch.
- App build number is 22.

## Build 21

- Investigated current Google service health: no broad severe Gemini outage is publicly reported at this time; current official Gemini docs still support Google Search grounding on Gemini 2.5 Flash/Flash-Lite.
- Hardened `web_search`: Gemini 2.5 Flash-Lite is now the primary low-latency search model, with Gemini 2.5 Flash fallback.
- Added retry/backoff for transient 429/5xx/network failures instead of failing immediately after one REST request.
- Search diagnostics now record model, attempt, HTTP/transport error, transient classification, and successful completion without logging the private query text.
- Increased built-in iPhone JARVIS PCM loudness in software by 2.5x with a limiter. Bluetooth/glasses playback remains at unity gain.
- Added PCM peak/gain diagnostics so low source amplitude can be distinguished from a routing/system-volume problem.
- App build number is 21.

## Build 20

- Fixed the missing wake acknowledgement sound by eliminating audio-session churn immediately after wake detection and making SoundService the single chime owner.
- Wake chime now re-asserts the built-in loudspeaker before playback, uses full app-level player gain, and logs asset duration, route, and system volume.
- Phone hands-free audio uses AVAudioSession videoChat mode plus explicit speaker override while retaining AVAudioEngine voice processing/AEC.
- Speaker override is now re-asserted even when iOS already labels the route as built-in Speaker, because route renegotiation can leave a low voice-output path behind.
- Gemini PCM playback re-asserts the phone loudspeaker after its playback engine starts and at the beginning of each fresh reply.
- Added richer audio diagnostics (route + read-only system volume) to distinguish routing problems from the user's hardware volume setting.
- Removed the obsolete VoiceCommandService activation_chime.wav player; that resource does not exist and duplicated SoundService behavior.
- App build number is 20.

## Build 19

- Fixed build 18 backend regression for free-tier Gemini keys.
- Removed built-in Gemini 3 Google Search grounding from the Live session setup because current Gemini pricing marks Gemini 3 Search grounding unavailable on the free tier; this prevented setupComplete and surfaced as a generic backend failure.
- Added native `web_search` tool that performs current-information lookup separately through `gemini-2.5-flash` + Google Search grounding, preserving the free Live voice session while still supporting current sports/news/web questions.
- Added explicit diagnostics for root-level Gemini WebSocket API errors so future setup failures expose their actual server message.
- App build number is 19.

## Build 18

- Enabled Gemini 3.1 Flash Live built-in Google Search grounding alongside the existing native iPhone function tools. Current/time-sensitive questions such as sports schedules/results can now be searched instead of being refused.
- Added explicit prompt routing for internet/current-information requests.
- Fixed wake-word sound asset lookup for both flattened resources and the `Sounds/` bundle directory; preloads the chime and logs whether playback actually started.
- Hardened phone audio routing: explicitly prefers the built-in mic and re-forces the loudspeaker after voice-processing/AVAudioEngine route renegotiation.
- Wake-word/command recognition prefers on-device Apple Speech when pt-BR on-device recognition is available.
- Leaving the Voice tab no longer stops the wake listener; background audio can keep the already-running voice runtime alive after the app has been launched.
- Added app scene-phase diagnostics and foreground recovery if iOS kills the recognizer during a background/audio interruption.
- Important iOS boundary: this improves background operation while the app remains running, but a normal third-party app still cannot cold-launch itself from a custom microphone phrase after being force-quit/terminated.
- Final source commit is ready for the normal unsigned iOS build pipeline.
- App build number is 18.

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
