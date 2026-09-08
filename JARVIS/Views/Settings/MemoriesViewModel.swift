import Foundation
import Combine

@MainActor
final class MemoriesViewModel: ObservableObject {
    @Published private(set) var memories: [BrainMemory] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let brain: BrainService

    init(brain: BrainService = .shared) {
        self.brain = brain
    }

    func reload() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            memories = try await brain.listActiveMemories(limit: 500)
        } catch {
            memories = []
            errorMessage = "Não foi possível carregar as memórias."
        }
    }

    func saveNew(key: String, value: String) async {
        errorMessage = nil

        let normalizedKey = BrainLegacyKey.normalize(key)
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty, !trimmedValue.isEmpty else {
            errorMessage = "Informe uma chave e um valor para a memória."
            return
        }

        do {
            _ = try await brain.rememberLegacy(
                key: normalizedKey,
                value: trimmedValue,
                source: .manualEdit
            )
            await reload()
        } catch {
            errorMessage = "Não foi possível salvar a memória."
        }
    }

    func update(memory: BrainMemory, value: String) async {
        errorMessage = nil

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            errorMessage = "Informe um valor para a memória."
            return
        }

        do {
            _ = try await brain.updateMemoryContent(
                id: memory.id,
                content: trimmedValue,
                source: .manualEdit
            )
            await reload()
        } catch {
            errorMessage = "Não foi possível atualizar a memória."
        }
    }

    func forget(memory: BrainMemory) async {
        errorMessage = nil

        do {
            _ = try await brain.forgetMemory(id: memory.id, source: .manualEdit)
            await reload()
        } catch {
            errorMessage = "Não foi possível apagar a memória."
        }
    }
}