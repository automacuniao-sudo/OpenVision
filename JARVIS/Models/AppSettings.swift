// JARVIS - AppSettings.swift
// Settings data model with Codable support for JSON persistence

import Foundation

/// The type of AI backend to use
enum AIBackendType: String, Codable, CaseIterable {
    case openClaw = "openclaw"
    case geminiLive = "gemini_live"
    case openAI = "openai"
    case appleFoundation = "apple_foundation"
    case localGemma = "local_gemma"

    var displayName: String {
        switch self {
        case .openClaw: return "OpenClaw"
        case .geminiLive: return "Gemini Live"
        case .openAI: return "OpenAI"
        case .appleFoundation: return "Apple Intelligence"
        case .localGemma: return "Local (MLX)"
        }
    }

    var description: String {
        switch self {
        case .openClaw:
            return "Wake word activation, 56+ tools, task execution"
        case .geminiLive:
            return "Real-time voice + visual context, continuous conversation"
        case .openAI:
            return "GPT-4o — cloud text + image understanding (OpenAI-compatible)"
        case .appleFoundation:
            return "On-device Apple model — private, no download (iOS 26+)"
        case .localGemma:
            return "On-device Gemma 4 — private, offline, no API cost"
        }
    }

    var icon: String {
        switch self {
        case .openClaw: return "terminal"
        case .geminiLive: return "waveform"
        case .openAI: return "sparkles"
        case .appleFoundation: return "apple.logo"
        case .localGemma: return "cpu"
        }
    }
}

enum TTSEngineType: String, Codable, CaseIterable, Identifiable {
    case appleSystem = "apple"
    case kokoro = "kokoro"
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .appleSystem: return "Apple (system voice)"
        case .kokoro: return "Kokoro (natural, on-device)"
        }
    }
}

struct AppSettings: Codable, Equatable {
    var aiBackend: AIBackendType = .openClaw

    var openClawGatewayURL: String = ""
    var openClawAuthToken: String = ""

    var geminiAPIKey: String = ""
    var geminiVoiceName: String = "Charon"

    var openAIAPIKey: String = ""
    /// Chat model id. gpt-4o-mini is cheap and supports image understanding — a good default for testing.
    var openAIModel: String = "gpt-4o-mini"
    var openAIBaseURL: String = "https://api.openai.com/v1"
    var openAIRealtimeModel: String = "gpt-realtime"
    var openAIRealtimeVoice: String = "marin"

    /// Tavily API key (free tier). When set, web search uses Tavily as the primary source,
    /// falling back to keyless DuckDuckGo if Tavily is unavailable.
    var tavilyAPIKey: String = ""

    /// Public Spotify Developer Client ID. OAuth tokens are stored separately in Keychain.
    var spotifyClientID: String = ""

    var localGemmaModelId: String = "mlx-community/gemma-4-E2B-it-4bit"
    var localGemmaModelReady: Bool = false

    /// Wake word phrase for JARVIS.
    var wakeWord: String = "Ok Jarvis"
    var wakeWordEnabled: Bool = true
    var playActivationSound: Bool = true
    var conversationTimeout: TimeInterval = 30
    var selectedVoiceIdentifier: String? = nil
    var ttsEngine: TTSEngineType = .appleSystem
    var kokoroVoice: String = "af_heart"

    // MARK: - Telemetry (opt-in, self-hosted)
    // Numeric timing/device metrics only — never transcripts, prompts, replies or tool arguments.
    var telemetryEnabled: Bool = false
    var telemetryURL: String = ""
    var telemetryBucket: String = "metrics"
    var telemetryOrg: String = "jarvis"
    var telemetryToken: String = ""
    var telemetryUsername: String = ""
    var telemetryPassword: String = ""
    var telemetryDeviceName: String = "iphone"

    var preferGlassesMic: Bool = true

    /// Beta speaker-verification lock. When enabled, JARVIS verifies each STT command locally
    /// before forwarding it to any backend. Gemini Live switches from raw PCM input to verified
    /// text turns so another speaker cannot inject commands into the active session.
    var voiceOwnerLockEnabled: Bool = false
    /// CAM++ cosine-similarity threshold. Tunable because microphone/room conditions vary.
    var voiceOwnerSimilarityThreshold: Double = 0.65

    var userPrompt: String = ""
    var memories: [String: String] = [:]
    var jarvisProfileSeedVersion: Int = 0

    var autoReconnect: Bool = true
    var showTranscripts: Bool = true
    var geminiVideoFPS: Int = 1

    var isOpenClawConfigured: Bool {
        !openClawGatewayURL.isEmpty && !openClawAuthToken.isEmpty
    }

    var isGeminiConfigured: Bool {
        !geminiAPIKey.isEmpty
    }

    var isOpenAIConfigured: Bool {
        !openAIAPIKey.isEmpty && !openAIBaseURL.isEmpty
    }

    var isSpotifyConfigured: Bool {
        !spotifyClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isLocalGemmaConfigured: Bool {
        localGemmaModelReady
    }

    var isCurrentBackendConfigured: Bool {
        switch aiBackend {
        case .openClaw: return isOpenClawConfigured
        case .geminiLive: return isGeminiConfigured
        case .openAI: return isOpenAIConfigured
        case .appleFoundation: return true
        case .localGemma: return isLocalGemmaConfigured
        }
    }

    var backendDisplayName: String {
        guard aiBackend == .localGemma else { return aiBackend.displayName }
        return "Local · \(GemmaLocalModel.from(modelId: localGemmaModelId).displayName)"
    }
}
