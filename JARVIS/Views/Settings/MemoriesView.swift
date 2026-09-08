// OpenVision - MemoriesView.swift
// AI memories management backed by the canonical BrainService.

import SwiftUI

struct MemoriesView: View {
    @StateObject private var viewModel = MemoriesViewModel()

    @State private var selectedMemory: BrainMemory?
    @State private var showingEditor = false
    @State private var showingDeleteConfirmation = false
    @State private var memoryToDelete: BrainMemory?

    var body: some View {
        List {
            if let errorMessage = viewModel.errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if viewModel.isLoading && viewModel.memories.isEmpty {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding(.vertical, 24)
                }
            } else if viewModel.memories.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "brain")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)

                        Text("No memories yet")
                            .font(.headline)

                        Text("Add memories manually to give the AI context about you.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                }
            } else {
                Section {
                    ForEach(viewModel.memories) { memory in
                        Button {
                            selectedMemory = memory
                            showingEditor = true
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(Self.label(for: memory))
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .foregroundColor(.primary)

                                Text(memory.content)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                            .padding(.vertical, 4)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                memoryToDelete = memory
                                showingDeleteConfirmation = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("Stored Memories")
                } footer: {
                    Text("\(viewModel.memories.count) memories")
                }
            }
        }
        .navigationTitle("Memories")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    selectedMemory = nil
                    showingEditor = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .task {
            await viewModel.reload()
        }
        .sheet(isPresented: $showingEditor) {
            MemoryEditorView(
                viewModel: viewModel,
                existingMemory: selectedMemory
            )
        }
        .confirmationDialog(
            "Delete Memory",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let memory = memoryToDelete else { return }
                Task {
                    await viewModel.forget(memory: memory)
                    memoryToDelete = nil
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let memory = memoryToDelete {
                Text("Are you sure you want to delete '\(Self.label(for: memory))'?")
            }
        }
    }

    private static func label(for memory: BrainMemory) -> String {
        memory.legacyKey ?? "memory_\(memory.id.uuidString.prefix(8).lowercased())"
    }
}

// MARK: - Memory Editor View

struct MemoryEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: MemoriesViewModel

    let existingMemory: BrainMemory?

    @State private var key = ""
    @State private var value = ""
    @State private var showingDeleteConfirmation = false
    @State private var isSaving = false

    var isNewMemory: Bool { existingMemory == nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Key")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("user_name", text: $key)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .disabled(!isNewMemory)
                    }
                } header: {
                    Text("Identifier")
                } footer: {
                    Text("A short identifier (e.g., 'user_name', 'favorite_color')")
                }

                Section {
                    TextEditor(text: $value)
                        .frame(minHeight: 100)
                } header: {
                    Text("Value")
                } footer: {
                    Text("The information to remember")
                }

                if let errorMessage = viewModel.errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if !isNewMemory {
                    Section {
                        Button(role: .destructive) {
                            showingDeleteConfirmation = true
                        } label: {
                            HStack {
                                Spacer()
                                Label("Delete Memory", systemImage: "trash")
                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle(isNewMemory ? "New Memory" : "Edit Memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveMemory()
                    }
                    .disabled(
                        isSaving ||
                        key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }

                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isSaving)
                }
            }
            .onAppear {
                if let existingMemory {
                    key = existingMemory.legacyKey ?? "memory_\(existingMemory.id.uuidString.prefix(8).lowercased())"
                    value = existingMemory.content
                } else {
                    key = ""
                    value = ""
                }
            }
            .confirmationDialog(
                "Delete Memory",
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    guard let existingMemory else { return }
                    Task {
                        await viewModel.forget(memory: existingMemory)
                        if viewModel.errorMessage == nil {
                            dismiss()
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Are you sure you want to delete this memory?")
            }
        }
    }

    private func saveMemory() {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)

        isSaving = true
        Task {
            if let existingMemory {
                await viewModel.update(memory: existingMemory, value: trimmedValue)
            } else {
                await viewModel.saveNew(key: trimmedKey, value: trimmedValue)
            }

            isSaving = false
            if viewModel.errorMessage == nil {
                dismiss()
            }
        }
    }
}

#Preview {
    NavigationStack {
        MemoriesView()
    }
}
