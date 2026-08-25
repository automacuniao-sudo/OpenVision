// OpenVision - ConversationListView.swift
// List of past conversations with search, delete, copy, and export

import SwiftUI
import UIKit

struct ConversationListView: View {
    // MARK: - Environment

    @EnvironmentObject var settingsManager: SettingsManager

    // The single source of truth. The old version kept a local @State copy that was never
    // even populated — History was permanently empty.
    @ObservedObject private var conversationManager = ConversationManager.shared

    // MARK: - State

    @State private var searchText: String = ""

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                if conversationManager.conversations.isEmpty {
                    emptyState
                } else {
                    conversationList
                }
            }
            .navigationTitle("History")
            .searchable(text: $searchText, prompt: "Search conversations")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        // Fresh conversation: next exchange starts a new History entry with
                        // no carried-over model context.
                        conversationManager.startNewConversation()
                        ConversationContext.shared.clear()
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("No conversations yet")
                .font(.headline)

            Text("Start a conversation with the AI assistant to see your history here.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    // MARK: - Conversation List

    private var conversationList: some View {
        List {
            ForEach(filteredConversations) { conversation in
                NavigationLink {
                    ConversationDetailView(conversation: conversation)
                } label: {
                    ConversationRow(conversation: conversation)
                }
            }
            .onDelete(perform: deleteConversations)
        }
        .listStyle(.plain)
    }

    // MARK: - Filtered Conversations

    private var filteredConversations: [Conversation] {
        conversationManager.search(searchText)
    }

    // MARK: - Methods

    private func deleteConversations(at offsets: IndexSet) {
        // Resolve against the FILTERED list (offsets come from it), then delete via the
        // manager so the removal persists.
        let targets = offsets.map { filteredConversations[$0] }
        for conversation in targets {
            conversationManager.deleteConversation(conversation)
        }
    }
}

// MARK: - Conversation Row

struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(conversation.title)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                Text(conversation.lastActivityAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let lastMessage = conversation.messages.last {
                Text(lastMessage.content)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            HStack {
                Label("\(conversation.messages.count)", systemImage: "bubble.left")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if conversation.hasPhotos {
                    Label("", systemImage: "photo")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Conversation Detail View

struct ConversationDetailView: View {
    let conversation: Conversation
    @State private var resumed = false
    @State private var copied = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(conversation.messages) { message in
                    MessageBubble(message: message)
                }
            }
            .padding()
        }
        .navigationTitle(conversation.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button {
                        copyConversation()
                    } label: {
                        Label(copied ? "Conversa copiada" : "Copiar conversa", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }

                    ShareLink(
                        item: exportText,
                        subject: Text("Conversa JARVIS"),
                        message: Text(conversation.title)
                    ) {
                        Label("Exportar conversa", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Copiar ou exportar conversa")

                Button {
                    // Continue this conversation: make it current (new messages append to it)
                    // and reload its recent exchanges as the model's live context, so the next
                    // "Ok Jarvis" follow-up picks up where it left off.
                    ConversationManager.shared.resumeConversation(conversation)
                    ConversationContext.shared.seed(from: conversation)
                    resumed = true
                } label: {
                    Label(resumed ? "Resumed" : "Continue", systemImage: resumed ? "checkmark.circle" : "arrow.right.circle")
                }
                .disabled(resumed)
            }
        }
    }

    private func copyConversation() {
        UIPasteboard.general.string = exportText
        copied = true
        DiagnosticLogger.shared.log(
            "History",
            "Copied conversation messages=\(conversation.messages.count)"
        )
    }

    /// Plain-text export designed to be useful in WhatsApp, Notes, email, bug reports, or when
    /// pasting a complete JARVIS exchange back into ChatGPT for debugging.
    private var exportText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "dd/MM/yyyy HH:mm:ss"

        let timeZone = TimeZone.autoupdatingCurrent.identifier
        let created = formatter.string(from: conversation.createdAt)
        let header = "JARVIS — \(conversation.title)\nCriada em: \(created)\nFuso do iPhone: \(timeZone)"

        let body = conversation.messages.map { message in
            let role: String
            switch message.role {
            case .user:
                role = "Você"
            case .assistant:
                role = "JARVIS"
            case .system:
                role = "Sistema"
            case .tool:
                role = message.toolName.map { "Ferramenta (\($0))" } ?? "Ferramenta"
            }
            return "[\(formatter.string(from: message.timestamp))] \(role): \(message.content)"
        }.joined(separator: "\n\n")

        return body.isEmpty ? header : "\(header)\n\n\(body)"
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: Message

    var body: some View {
        HStack {
            // User on the right, assistant on the left — same as the live transcript.
            if message.role == .user {
                Spacer(minLength: 40)
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                Text(message.content)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(message.role == .user ? AnyShapeStyle(Theme.buttonGradient) : AnyShapeStyle(Color(.systemGray5)))
                    .foregroundColor(message.role == .user ? Color.black.opacity(0.9) : .primary)
                    .cornerRadius(16)

                Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if message.role == .assistant {
                Spacer(minLength: 40)
            }
        }
    }
}

#Preview {
    ConversationListView()
        .environmentObject(SettingsManager.shared)
}
