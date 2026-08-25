// JARVIS - WebSearchSettingsView.swift
// Configure and validate Tavily, with DuckDuckGo as automatic fallback.

import SwiftUI

struct WebSearchSettingsView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    @State private var apiKey: String = ""
    @State private var isTesting = false
    @State private var testMessage: String?
    @State private var testSucceeded = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tavily API Key")
                        .font(.caption).foregroundColor(.secondary)
                    SecureField("tvly-…", text: $apiKey)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                }
            } header: {
                Text("Tavily (recommended)")
            } footer: {
                if apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
                    Label("Sem chave — JARVIS usa DuckDuckGo como fallback.", systemImage: "info.circle")
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    Label("Chave salva. Use Test Tavily para confirmar que a API está funcionando.", systemImage: "key.fill")
                        .font(.caption).foregroundColor(.secondary)
                }
            }

            Section {
                Button {
                    testTavily()
                } label: {
                    HStack {
                        Label("Test Tavily", systemImage: "checkmark.shield")
                        Spacer()
                        if isTesting {
                            ProgressView()
                        }
                    }
                }
                .disabled(isTesting || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if let testMessage {
                    Label(
                        testMessage,
                        systemImage: testSucceeded ? "checkmark.circle.fill" : "xmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundColor(testSucceeded ? .green : .red)
                }
            } header: {
                Text("Connection Test")
            } footer: {
                Text("O teste faz uma chamada real ao Tavily. Nenhuma chave é gravada nos Diagnostics.")
            }

            Section {
                Link(destination: URL(string: "https://app.tavily.com")!) {
                    HStack {
                        Text("Get a free Tavily key")
                        Spacer()
                        Image(systemName: "arrow.up.right.square").foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Help")
            } footer: {
                Text("Tavily é a fonte principal para pesquisas atuais. Se ele falhar, JARVIS cai automaticamente para DuckDuckGo e registra qual provedor respondeu nos Diagnostics.")
            }
        }
        .navigationTitle("Web Search")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { apiKey = settingsManager.settings.tavilyAPIKey }
        .onDisappear { save() }
        .onChange(of: apiKey) { _ in
            testMessage = nil
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
            }
        }
    }

    private func save() {
        settingsManager.settings.tavilyAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        settingsManager.saveNow()
    }

    private func testTavily() {
        save()
        isTesting = true
        testMessage = nil

        Task { @MainActor in
            let result = await WebSearchService.testTavily(apiKey: apiKey)
            testSucceeded = result.success
            testMessage = result.message
            isTesting = false
        }
    }
}

#Preview {
    NavigationStack {
        WebSearchSettingsView().environmentObject(SettingsManager.shared)
    }
}
