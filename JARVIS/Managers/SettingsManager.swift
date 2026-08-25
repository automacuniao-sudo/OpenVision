// OpenVision - SettingsManager.swift
// Singleton manager for settings persistence with debounced auto-save

import Foundation
import Combine

/// Manages app settings with JSON persistence and debounced saving
@MainActor
final class SettingsManager: ObservableObject {
    // MARK: - Singleton

    static let shared = SettingsManager()

    // MARK: - Published Properties

    /// Current app settings - changes trigger debounced save
    @Published var settings: AppSettings {
        didSet {
            if settings != oldValue {
                scheduleSave()
            }
        }
    }

    // MARK: - Private Properties

    private let settingsURL: URL
    private var saveTask: Task<Void, Never>?
    private let debounceInterval: TimeInterval = 0.5

    // MARK: - Callbacks

    /// Called when settings change (for live session updates)
    var onSettingsChanged: ((AppSettings) -> Void)?

    // MARK: - Initialization

    private init() {
        // Set up file URL
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        settingsURL = documentsURL.appendingPathComponent("settings.json")

        // Load existing settings or create defaults, then apply the Project JARVIS starter
        // profile exactly once. Existing user text/memories always win.
        var loaded = Self.loadSettings(from: settingsURL)
        let seededProfile = Self.seedJarvisProfileIfNeeded(&loaded)
        settings = loaded
        if seededProfile { Self.persistSettings(loaded, to: settingsURL) }

        print("[SettingsManager] Initialized with settings from: \(settingsURL.path)")
    }

    // MARK: - Public Methods

    /// Save settings immediately (use on app background/disappear)
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        performSave()
    }

    /// Reset settings to defaults
    func resetToDefaults() {
        settings = AppSettings()
        saveNow()
    }

    // MARK: - Memory Management

    /// Add or update a memory
    func setMemory(key: String, value: String) {
        settings.memories[key] = value
    }

    /// Delete a memory
    func deleteMemory(key: String) {
        settings.memories.removeValue(forKey: key)
    }

    /// Rename a memory key
    func renameMemory(oldKey: String, newKey: String) {
        guard let value = settings.memories[oldKey] else { return }
        settings.memories.removeValue(forKey: oldKey)
        settings.memories[newKey] = value
    }

    // MARK: - Private Methods

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            // NOTE: was UInt64(debounceInterval) which is UInt64(0.5) == 0 — no delay. Multiply into
            // nanoseconds first so the debounce actually coalesces rapid edits (e.g. typing a key).
            let seconds = self?.debounceInterval ?? 0.5
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.performSave()
            self?.onSettingsChanged?(self?.settings ?? AppSettings())
        }
    }

    private func performSave() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(settings)
            try data.write(to: settingsURL, options: .atomic)
            print("[SettingsManager] Settings saved")
        } catch {
            print("[SettingsManager] Error saving settings: \(error)")
        }
    }

    private static func persistSettings(_ settings: AppSettings, to url: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(settings).write(to: url, options: .atomic)
            print("[SettingsManager] Seeded Project JARVIS profile defaults")
        } catch {
            print("[SettingsManager] Failed to persist seeded JARVIS profile: \(error)")
        }
    }

    /// Fill the Settings UI with useful JARVIS defaults once, without ever overwriting user edits.
    private static func seedJarvisProfileIfNeeded(_ settings: inout AppSettings) -> Bool {
        guard settings.jarvisProfileSeedVersion < 1 else { return false }

        if settings.userPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            settings.userPrompt = """
            Você é o JARVIS, meu assistente pessoal do Projeto JARVIS.
            Responda em português brasileiro, salvo se eu pedir explicitamente outro idioma.
            Priorize respostas curtas, naturais e úteis para uso por voz e sem as mãos.
            Quando eu pedir uma ação no iPhone e existir uma ferramenta nativa, execute a ferramenta em vez de apenas explicar como fazer.
            Para fatos atuais — como placares, próximos jogos, notícias, preços, clima, lançamentos e informações que podem ter mudado — use web_search antes de responder.
            Nunca afirme que executou uma ação se a ferramenta não confirmou sucesso.
            Para fatos sobre mim ou sobre o Projeto JARVIS, use Memories e My Documents quando apropriado e não invente informações ausentes.
            Diferencie claramente o que você sabe do que realmente consegue executar no iPhone ou nos óculos Meta/Ray-Ban Meta.
            """
        }

        let starterMemories: [String: String] = [
            "idioma_preferido": "Português brasileiro (pt-BR).",
            "projeto_principal": "Projeto JARVIS: assistente pessoal hands-free integrado ao iPhone e aos óculos Meta/Ray-Ban Meta.",
            "hardware_alvo": "Meta/Ray-Ban Meta é o óculos oficial do Projeto JARVIS; o iPhone funciona como hub principal.",
            "estilo_de_resposta": "Direto, natural e técnico quando necessário, sem exageros; respostas por voz devem ser objetivas.",
            "objetivo_de_uso": "Usar o JARVIS no dia a dia pelos óculos para conversar, perceber contexto e executar ações reais no iPhone.",
            "fluxo_de_desenvolvimento": "O app iOS é desenvolvido no Windows, compilado no GitHub Actions e instalado no iPhone por Sideloadly; não depende de Xcode/Mac no fluxo atual."
        ]
        for (key, value) in starterMemories where settings.memories[key] == nil {
            settings.memories[key] = value
        }

        settings.jarvisProfileSeedVersion = 1
        return true
    }

    private static func loadSettings(from url: URL) -> AppSettings {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            print("[SettingsManager] No settings file, using defaults")
            return createDefaultSettings()
        }

        // Strict decode first — succeeds when every field is present.
        if let settings = try? JSONDecoder().decode(AppSettings.self, from: data) {
            print("[SettingsManager] Loaded settings from file")
            return settings
        }

        // Lenient fallback. Synthesized Codable throws on ANY missing key, so a settings.json
        // written by an older build (before a field was added) would otherwise reset EVERYTHING to
        // defaults — silently wiping saved API keys. Instead, overlay the on-disk values onto the
        // defaults' JSON (so present keys keep the user's value, missing keys fall back to default)
        // and decode the merge. This makes adding new settings fields non-destructive.
        let defaults = createDefaultSettings()
        if let defaultsData = try? JSONEncoder().encode(defaults),
           var merged = (try? JSONSerialization.jsonObject(with: defaultsData)) as? [String: Any],
           let onDisk = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            for (key, value) in onDisk { merged[key] = value }   // on-disk value wins where present
            if let mergedData = try? JSONSerialization.data(withJSONObject: merged),
               let settings = try? JSONDecoder().decode(AppSettings.self, from: mergedData) {
                print("[SettingsManager] Loaded settings via lenient merge (older file, missing fields filled)")
                return settings
            }
        }

        print("[SettingsManager] Could not decode settings even leniently — using defaults")
        return defaults
    }

    private static func createDefaultSettings() -> AppSettings {
        var settings = AppSettings()

        // Apply any build-time defaults from Config
        if !Config.defaultOpenClawGatewayURL.isEmpty {
            settings.openClawGatewayURL = Config.defaultOpenClawGatewayURL
        }
        if !Config.defaultOpenClawAuthToken.isEmpty {
            settings.openClawAuthToken = Config.defaultOpenClawAuthToken
        }
        if !Config.defaultGeminiAPIKey.isEmpty {
            settings.geminiAPIKey = Config.defaultGeminiAPIKey
        }

        return settings
    }
}
