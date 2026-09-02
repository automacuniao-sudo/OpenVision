// JARVIS - SettingsView.swift
// Main settings menu with navigation to configuration panels

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    @EnvironmentObject var glassesManager: GlassesManager

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        AIBackendSettingsView()
                    } label: {
                        HStack {
                            Label("AI Backend", systemImage: "cpu")
                            Spacer()
                            Text(settingsManager.settings.aiBackend.displayName)
                                .foregroundColor(.secondary)
                            if !settingsManager.settings.isCurrentBackendConfigured {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundColor(.orange)
                            }
                        }
                    }

                    NavigationLink {
                        WebSearchSettingsView()
                    } label: {
                        HStack {
                            Label("Web Search", systemImage: "magnifyingglass")
                            Spacer()
                            Text(settingsManager.settings.tavilyAPIKey.isEmpty ? "DuckDuckGo" : "Tavily")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if settingsManager.settings.aiBackend == .geminiLive {
                        NavigationLink {
                            AdditionalInstructionsView()
                        } label: {
                            Label("Custom Instructions", systemImage: "text.quote")
                        }

                        NavigationLink {
                            MemoriesView()
                        } label: {
                            HStack {
                                Label("Memories", systemImage: "brain")
                                Spacer()
                                Text("\(settingsManager.settings.memories.count)")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("AI")
                }

                Section {
                    NavigationLink {
                        GlassesSettingsView()
                    } label: {
                        HStack {
                            Label("Glasses", systemImage: "eyeglasses")
                            Spacer()
                            if glassesManager.isRegistered {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                            } else {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                } header: {
                    Text("Hardware")
                }

                Section {
                    NavigationLink {
                        VoiceSettingsView()
                    } label: {
                        HStack {
                            Label("Voice Control", systemImage: "mic.fill")
                            Spacer()
                            if settingsManager.settings.wakeWordEnabled {
                                Text(settingsManager.settings.wakeWord)
                                    .foregroundColor(.secondary)
                            } else {
                                Text("Off")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Voice")
                }

                Section {
                    NavigationLink {
                        DocumentsSettingsView()
                    } label: {
                        Label("My Documents", systemImage: "books.vertical")
                    }

                    NavigationLink {
                        TelemetrySettingsView()
                    } label: {
                        Label("Telemetry", systemImage: "chart.line.uptrend.xyaxis")
                    }

                    NavigationLink {
                        DiagnosticsView()
                    } label: {
                        Label("Diagnostics / Logs", systemImage: "waveform.path.ecg")
                    }

                    Toggle(isOn: $settingsManager.settings.autoReconnect) {
                        Label("Auto-Reconnect", systemImage: "arrow.triangle.2.circlepath")
                    }

                    Toggle(isOn: $settingsManager.settings.showTranscripts) {
                        Label("Show Transcripts", systemImage: "text.bubble")
                    }
                } header: {
                    Text("Advanced")
                }

                Section {
                    HStack {
                        Label("Version", systemImage: "info.circle")
                        Spacer()
                        Text("\(Config.appVersion) (\(Config.buildNumber))")
                            .foregroundColor(.secondary)
                    }

                    Link(destination: URL(string: "https://github.com/automacuniao-sudo/OpenVision/tree/jarvis-dev")!) {
                        Label("JARVIS Repository", systemImage: "link")
                    }

                    Link(destination: URL(string: "https://github.com/openclaw/openclaw")!) {
                        Label("Get OpenClaw", systemImage: "arrow.up.right.square")
                    }
                } header: {
                    Text("About JARVIS")
                } footer: {
                    Text("JARVIS is the customized assistant project developed on this branch.")
                }
            }
            .navigationTitle("JARVIS Settings")
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(SettingsManager.shared)
        .environmentObject(GlassesManager.shared)
}
