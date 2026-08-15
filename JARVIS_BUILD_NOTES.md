# Projeto JARVIS build notes

## Build 13

- Added in-app Diagnostics / Logs screen for testing without Xcode or a Mac.
- Logs speech recognition, Gemini connection/turns/audio chunks, and audio playback.
- Changed Apple Speech Recognition locale from en-US to pt-BR.
- Uses dictation mode for commands after the wake word, while keeping short-phrase search for wake-word detection.
- Gemini Live system instruction now defaults replies to Brazilian Portuguese unless another language is explicitly requested.
- Fixed Voice Control > Auto-End Timeout so the configured value is actually used; Never (0) disables the app-side silence timer.
- App build number is 13.
