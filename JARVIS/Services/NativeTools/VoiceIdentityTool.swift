// JARVIS - VoiceIdentityTool.swift
// Manage the local owner voice profile and beta owner-only command lock.

import Foundation

struct VoiceIdentityTool: NativeTool {
    let name = "voice_identity"
    let description = """
    Manage JARVIS's local speaker-recognition profile. Use 'enroll' when the user asks to cadastrar/salvar/minha voz;     'verify' when they ask whether JARVIS recognizes the current speaker; 'status' for configuration;     'enable_lock' or 'disable_lock' for owner-only voice commands; and 'forget' to erase the saved voice.     Voice embeddings stay on the iPhone and are never sent to the AI provider.
    """

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "enum": ["enroll", "verify", "status", "enable_lock", "disable_lock", "forget"]
            ],
            "name": [
                "type": "string",
                "description": "Owner name for enroll, if provided."
            ]
        ],
        "required": ["action"]
    ]

    func execute(args: [String: Any]) async throws -> String {
        let action = (args["action"] as? String ?? "status").lowercased()
        let service = SpeakerVerificationService.shared

        switch action {
        case "enroll":
            let name = (args["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return await service.enrollRecentVoice(name: name)

        case "verify":
            let threshold = await MainActor.run {
                Float(SettingsManager.shared.settings.voiceOwnerSimilarityThreshold)
            }
            let result = await service.verifyRecentVoice(threshold: threshold)
            guard let score = result.similarity else {
                return service.hasOwnerProfile
                    ? "Não consegui voz suficiente para validar o locutor agora."
                    : "Ainda não existe um perfil de voz cadastrado."
            }
            return result.isMatch
                ? String(format: "A voz atual corresponde ao perfil do proprietário %@ (similaridade %.2f). Responda diretamente ao usuário em segunda pessoa; não o apresente como uma terceira pessoa.", service.ownerProfileName ?? "cadastrado", score)
                : String(format: "A voz atual não corresponde ao proprietário cadastrado (similaridade %.2f). Não atribua outra identidade sem evidência.", score)

        case "enable_lock":
            guard service.hasOwnerProfile else {
                return "Cadastre sua voz primeiro. O bloqueio por voz não foi ativado."
            }
            await MainActor.run {
                SettingsManager.shared.settings.voiceOwnerLockEnabled = true
                SettingsManager.shared.saveNow()
            }
            return "Owner Voice Lock ativado. A partir da próxima ativação do JARVIS, cada comando será validado localmente antes de chegar à IA."

        case "disable_lock":
            await MainActor.run {
                SettingsManager.shared.settings.voiceOwnerLockEnabled = false
                SettingsManager.shared.saveNow()
            }
            return "Owner Voice Lock desativado."

        case "forget":
            service.forgetOwnerProfile()
            await MainActor.run {
                SettingsManager.shared.settings.voiceOwnerLockEnabled = false
                SettingsManager.shared.saveNow()
            }
            return "Perfil de voz apagado e Owner Voice Lock desativado."

        default:
            let enabled = await MainActor.run {
                SettingsManager.shared.settings.voiceOwnerLockEnabled
            }
            if let name = service.ownerProfileName {
                return "Perfil de voz cadastrado para \(name), com \(service.ownerSampleCount) amostra(s). Owner Voice Lock: \(enabled ? "ativado" : "desativado")."
            }
            return "Nenhum perfil de voz cadastrado. Owner Voice Lock está desativado."
        }
    }
}
