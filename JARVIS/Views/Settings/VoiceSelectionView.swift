// JARVIS - VoiceSelectionView.swift
// Voice picker for TTS output

import SwiftUI
import AVFoundation

struct VoiceSelectionView: View {
    @EnvironmentObject var settingsManager: SettingsManager

    @State private var voices: [AVSpeechSynthesisVoice] = []
    @State private var isTestingVoice: Bool = false
    @State private var testingVoiceId: String? = nil

    var body: some View {
        List {
            Section {
                voiceRow(
                    name: "Português (Brasil) padrão",
                    quality: nil,
                    identifier: nil,
                    isSelected: settingsManager.settings.selectedVoiceIdentifier == nil
                )
            } footer: {
                Text("Usa a voz padrão pt-BR disponível no iPhone para respostas em texto, incluindo OpenClaw.")
            }

            let premiumVoices = voices.filter { $0.quality == .premium }
            if !premiumVoices.isEmpty {
                Section {
                    ForEach(premiumVoices, id: \.identifier) { voice in
                        voiceRow(
                            name: voice.name,
                            quality: voice.quality,
                            identifier: voice.identifier,
                            isSelected: settingsManager.settings.selectedVoiceIdentifier == voice.identifier
                        )
                    }
                } header: {
                    Text("Vozes Premium")
                } footer: {
                    Text("Maior qualidade disponível no iPhone")
                }
            }

            let enhancedVoices = voices.filter { $0.quality == .enhanced }
            if !enhancedVoices.isEmpty {
                Section {
                    ForEach(enhancedVoices, id: \.identifier) { voice in
                        voiceRow(
                            name: voice.name,
                            quality: voice.quality,
                            identifier: voice.identifier,
                            isSelected: settingsManager.settings.selectedVoiceIdentifier == voice.identifier
                        )
                    }
                } header: {
                    Text("Vozes Aprimoradas")
                } footer: {
                    Text("Qualidade superior às vozes padrão")
                }
            }

            let defaultVoices = voices.filter { $0.quality == .default }
            if !defaultVoices.isEmpty {
                Section {
                    ForEach(defaultVoices, id: \.identifier) { voice in
                        voiceRow(
                            name: voice.name,
                            quality: voice.quality,
                            identifier: voice.identifier,
                            isSelected: settingsManager.settings.selectedVoiceIdentifier == voice.identifier
                        )
                    }
                } header: {
                    Text("Vozes Padrão")
                }
            }

            Section {
                Link(destination: URL(string: "App-prefs:ACCESSIBILITY&path=SPEECH")!) {
                    HStack {
                        Label("Baixar mais vozes", systemImage: "square.and.arrow.down")
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .foregroundColor(.secondary)
                    }
                }
            } footer: {
                Text("Baixe vozes brasileiras em Ajustes do iOS → Acessibilidade → Conteúdo Falado → Vozes → Português (Brasil).")
            }
        }
        .navigationTitle("Voz TTS")
        .onAppear {
            loadVoices()
        }
    }

    @ViewBuilder
    private func voiceRow(name: String, quality: AVSpeechSynthesisVoiceQuality?, identifier: String?, isSelected: Bool) -> some View {
        Button {
            selectVoice(identifier: identifier)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                        .foregroundColor(.primary)

                    if let quality = quality {
                        Text(TTSService.qualityDisplayName(quality))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                Button {
                    testVoice(identifier: identifier)
                } label: {
                    if testingVoiceId == identifier {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "play.circle")
                            .foregroundColor(Theme.accent)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isTestingVoice)

                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundColor(Theme.accent)
                        .fontWeight(.semibold)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func loadVoices() {
        voices = TTSService.availableVoices(for: "pt-BR")
    }

    private func selectVoice(identifier: String?) {
        settingsManager.settings.selectedVoiceIdentifier = identifier
    }

    private func testVoice(identifier: String?) {
        isTestingVoice = true
        testingVoiceId = identifier

        let utterance = AVSpeechUtterance(string: "Olá! Esta é a voz do JARVIS falando em português do Brasil.")

        if let identifier = identifier,
           let voice = AVSpeechSynthesisVoice(identifier: identifier),
           voice.language.lowercased().hasPrefix("pt") {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "pt-BR")
        }

        let synthesizer = AVSpeechSynthesizer()
        synthesizer.speak(utterance)

        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            isTestingVoice = false
            testingVoiceId = nil
        }
    }
}

#Preview {
    NavigationStack {
        VoiceSelectionView()
            .environmentObject(SettingsManager.shared)
    }
}
