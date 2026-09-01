// JARVIS - VoiceSettingsView.swift
// Voice control settings: wake word, conversation timeout

import SwiftUI
import AVFoundation

struct VoiceSettingsView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    @State private var savedOwnerVoiceName: String?
    @State private var showingForgetVoiceConfirmation = false

    private var selectedVoiceName: String {
        guard let identifier = settingsManager.settings.selectedVoiceIdentifier,
              let voice = AVSpeechSynthesisVoice(identifier: identifier) else {
            return "System Default"
        }
        return voice.name
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settingsManager.settings.wakeWordEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable Wake Word")
                        Text("Only listen after wake phrase")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if settingsManager.settings.wakeWordEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Wake Phrase")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("Ok Jarvis", text: $settingsManager.settings.wakeWord)
                            .autocorrectionDisabled()
                    }
                }
            } header: {
                Text("Wake Word")
            } footer: {
                if settingsManager.settings.wakeWordEnabled {
                    Text("Say \"\(settingsManager.settings.wakeWord)\" to activate JARVIS. This protects your privacy by only starting a command after the wake phrase.")
                } else {
                    Text("Wake word is disabled. The app will listen while the voice session is active.")
                }
            }

            Section {
                Toggle(isOn: $settingsManager.settings.preferGlassesMic) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use Glasses Mic")
                        Text("Listen through the glasses when worn")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Microphone")
            } footer: {
                Text("When on, voice input uses the glasses' Bluetooth microphone when it is available and falls back to the iPhone microphone automatically.")
            }

            Section {
                Toggle(isOn: Binding(
                    get: { settingsManager.settings.voiceOwnerLockEnabled },
                    set: { newValue in
                        guard !newValue || SpeakerVerificationService.shared.hasOwnerProfile else { return }
                        settingsManager.settings.voiceOwnerLockEnabled = newValue
                        settingsManager.saveNow()
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Owner Voice Lock (Beta)")
                        Text(savedOwnerVoiceName.map { "Only accept commands matching \($0)'s saved voice" }
                             ?? "Enroll your voice first by saying “cadastre minha voz”")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .disabled(!SpeakerVerificationService.shared.hasOwnerProfile)

                if let savedOwnerVoiceName {
                    HStack {
                        Text("Saved Voice")
                        Spacer()
                        Text(savedOwnerVoiceName).foregroundColor(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Similarity threshold: \(settingsManager.settings.voiceOwnerSimilarityThreshold, specifier: "%.2f")")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Slider(
                            value: $settingsManager.settings.voiceOwnerSimilarityThreshold,
                            in: 0.50...0.85,
                            step: 0.01
                        )
                    }

                    Button(role: .destructive) {
                        showingForgetVoiceConfirmation = true
                    } label: {
                        Label("Forget Saved Voice", systemImage: "person.wave.2.fill")
                    }
                }
            } header: {
                Text("Voice Security")
            } footer: {
                Text("Speaker verification runs locally with a CAM++ voice embedding. When enabled, each STT command is checked before being sent to the AI. This is useful for owner-only control but is not anti-replay authentication: a high-quality recording of your voice may still fool it.")
            }

            Section {
                Picker("Auto-End Timeout", selection: $settingsManager.settings.conversationTimeout) {
                    Text("15 seconds").tag(TimeInterval(15))
                    Text("30 seconds").tag(TimeInterval(30))
                    Text("1 minute").tag(TimeInterval(60))
                    Text("2 minutes").tag(TimeInterval(120))
                    Text("Never").tag(TimeInterval(0))
                }
            } header: {
                Text("Conversation")
            } footer: {
                Text("Automatically end the conversation after this period of silence.")
            }

            Section {
                Picker("Speech Engine", selection: $settingsManager.settings.ttsEngine) {
                    ForEach(TTSEngineType.allCases) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }

                if settingsManager.settings.ttsEngine == .appleSystem {
                    NavigationLink {
                        VoiceSelectionView()
                    } label: {
                        HStack {
                            Text("Apple Voice")
                            Spacer()
                            Text(selectedVoiceName).foregroundColor(.secondary)
                        }
                    }
                } else {
                    Picker("Kokoro Voice", selection: $settingsManager.settings.kokoroVoice) {
                        ForEach(KokoroTTSService.voices, id: \.self) { voice in
                            Text(voice).tag(voice)
                        }
                    }
                    NavigationLink {
                        KokoroSettingsView()
                    } label: {
                        HStack {
                            Label("Kokoro Model", systemImage: "waveform")
                            Spacer()
                            Text(KokoroTTSService.shared.isModelReady ? "Ready" : "Download")
                                .font(.caption)
                                .foregroundColor(KokoroTTSService.shared.isModelReady ? .green : .orange)
                        }
                    }
                }
            } header: {
                Text("Output Voice")
            } footer: {
                if settingsManager.settings.ttsEngine == .kokoro {
                    Text("Kokoro is a natural, on-device neural voice. Download its model first, then it runs locally.")
                } else {
                    Text("Apple's built-in system voice. Premium/Enhanced voices can be installed from iOS Settings.")
                }
            }

            Section {
                Toggle(isOn: $settingsManager.settings.playActivationSound) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Activation Sound")
                        Text("Play chime on wake word")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Feedback")
            }

            Section {
                HStack {
                    Text("Supported Phrases")
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(samplePhrases, id: \.self) { phrase in
                        HStack {
                            Image(systemName: "quote.bubble")
                                .foregroundColor(.secondary)
                            Text(phrase)
                                .font(.subheadline)
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Examples")
            } footer: {
                Text("JARVIS recognizes the configured phrase plus common Jarvis variants such as \"OK Jarvis\" and \"Hey Jarvis\".")
            }
        }
        .navigationTitle("JARVIS Voice")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            savedOwnerVoiceName = SpeakerVerificationService.shared.ownerProfileName
        }
        .confirmationDialog(
            "Forget saved owner voice?",
            isPresented: $showingForgetVoiceConfirmation,
            titleVisibility: .visible
        ) {
            Button("Forget Voice", role: .destructive) {
                SpeakerVerificationService.shared.forgetOwnerProfile()
                settingsManager.settings.voiceOwnerLockEnabled = false
                settingsManager.saveNow()
                savedOwnerVoiceName = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("JARVIS will stop using speaker verification until you enroll your voice again.")
        }
    }

    private var samplePhrases: [String] {
        let wake = settingsManager.settings.wakeWord
        return [
            "\(wake), qual é a previsão do tempo?",
            "\(wake), quanto de bateria eu tenho?",
            "\(wake), me lembre de...",
            "\(wake), pesquise..."
        ]
    }
}

#Preview {
    NavigationStack {
        VoiceSettingsView()
            .environmentObject(SettingsManager.shared)
    }
}
