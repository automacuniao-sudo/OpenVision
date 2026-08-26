// OpenVision - NativeTool.swift
// On-device productivity tools the AI calls via function-calling.
//
// Each tool is a small struct backed by a stable Apple framework (UserNotifications, EventKit,
// CoreLocation, UIPasteboard, UIKit) — deterministic and reliable, no vision/hallucination surface.
// The model decides WHEN to call one; the tool does the work and returns a short spoken result.
//
// Backends that support function-calling (OpenAI, Gemini, Apple Intelligence) expose these; the
// tiny local VLMs don't do reliable tool-calling, so they simply don't advertise them.

import Foundation

/// A single callable tool. Ships its own JSON Schema so the registry can advertise it to the model.
protocol NativeTool {
    var name: String { get }
    var description: String { get }
    var parametersSchema: [String: Any] { get }
    func execute(args: [String: Any]) async throws -> String
}

extension NativeTool {
    /// OpenAI Chat Completions tool spec (also close enough for other function-calling backends).
    var openAISpec: [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": parametersSchema
            ]
        ]
    }

    /// Gemini's `parameters` field is an OpenAPI-style Schema, not arbitrary JSON Schema.
    /// Some tools intentionally use JSON-Schema-only keywords (for example
    /// `additionalProperties: false`) for OpenAI strictness. Passing those keywords through
    /// unchanged can make Gemini Live reject the whole setup and close the WebSocket before
    /// `setupComplete`. Sanitize the schema centrally for Gemini while preserving the original
    /// schema for OpenAI and other backends.
    var geminiDeclaration: [String: Any] {
        [
            "name": name,
            "description": description,
            "parameters": Self.geminiCompatibleSchema(parametersSchema)
        ]
    }

    private static func geminiCompatibleSchema(_ value: [String: Any]) -> [String: Any] {
        var sanitized: [String: Any] = [:]
        for (key, rawValue) in value {
            // `additionalProperties` belongs to JSON Schema / parametersJsonSchema. The Live
            // session currently advertises declarations through FunctionDeclaration.parameters,
            // whose Schema message does not accept this field.
            if key == "additionalProperties" {
                continue
            }

            if let nested = rawValue as? [String: Any] {
                sanitized[key] = geminiCompatibleSchema(nested)
            } else if let array = rawValue as? [[String: Any]] {
                sanitized[key] = array.map { geminiCompatibleSchema($0) }
            } else {
                sanitized[key] = rawValue
            }
        }
        return sanitized
    }
}

/// Central registry of the available native tools. Read-only after init, so it's safe to read from
/// any thread (the backend's request loop runs off the main thread).
final class NativeToolRegistry {
    static let shared = NativeToolRegistry()

    private let tools: [String: NativeTool]

    private init() {
        let all: [NativeTool] = [
            TimerTool(),
            PomodoroTool(),
            ReminderTool(),
            CalendarTool(),
            ContextualNoteTool(),
            ClipboardTool(),
            DocumentSearchTool(),
            DeviceStatusTool(),
            CurrentDateTimeTool(),
            WebSearchTool(),
            LastSearchSourcesTool(),
        ]
        var map: [String: NativeTool] = [:]
        for t in all { map[t.name] = t }
        tools = map
    }

    /// Tool specs to advertise to the model.
    var openAISpecs: [[String: Any]] { tools.values.map(\.openAISpec) }

    /// Gemini function declarations to advertise in the Live API setup message.
    var geminiDeclarations: [[String: Any]] { tools.values.map(\.geminiDeclaration) }

    /// Whether a given tool name belongs to a native tool (vs. e.g. web_search).
    func isNativeTool(_ name: String) -> Bool { tools[name] != nil }

    /// Run a tool by name. Never throws — returns a spoken-friendly error string so the model can
    /// tell the user gracefully.
    func execute(name: String, args: [String: Any]) async -> String {
        guard let tool = tools[name] else { return "I don't have a tool called \(name)." }
        var args = args

        // Time sanity chokepoint (all backends pass through here): if the triggering utterance was
        // clearly relative ("in 15 minutes" / "daqui a 15 minutos"), trust the transcript over the
        // model's computed clock time. See NativeToolSupport.applyRelativeTimeGuard.
        if ["calendar", "create_reminder"].contains(name) {
            let command = await NativeToolContext.shared.recentCommand()
            if let rel = NativeToolSupport.applyRelativeTimeGuard(&args, command: command) {
                NSLog("[NativeTool] relative-time guard: overriding model time with %d min from utterance", rel)
                await MainActor.run {
                    DiagnosticLogger.shared.log("Tool", "Relative-time guard: \(name) -> \(rel) min")
                }
            }
        }

        // Log only tool name + parameter NAMES. Values can contain private note/event content.
        let keyList = args.keys.sorted().joined(separator: ", ")
        NSLog("[NativeTool] ▶ %@ (%@)", name, keyList)
        await MainActor.run {
            DiagnosticLogger.shared.log("Tool", "▶ \(name) keys=[\(keyList)]")
        }

        do {
            let result = try await tool.execute(args: args)
            NSLog("[NativeTool] ✔ %@", name)
            await MainActor.run {
                DiagnosticLogger.shared.log("Tool", "✔ \(name)")
            }
            return result
        } catch {
            NSLog("[NativeTool] ✘ %@ failed: %@", name, "\(error)")
            await MainActor.run {
                DiagnosticLogger.shared.log("Tool", "✘ \(name): \(error.localizedDescription)")
            }
            return "That didn't work: \(error.localizedDescription)"
        }
    }
}
