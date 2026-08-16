from pathlib import Path


def replace(path, old, new):
    p = Path(path)
    text = p.read_text()
    if old not in text:
        raise SystemExit(f'Pattern not found in {path}: {old[:160]!r}')
    p.write_text(text.replace(old, new, 1))

# Register the separate current-information search bridge.
replace(
    'OpenVision/Services/NativeTools/NativeTool.swift',
    '''            DocumentSearchTool(),\n            DeviceStatusTool(),\n''',
    '''            DocumentSearchTool(),\n            DeviceStatusTool(),\n            WebSearchTool(),\n'''
)

# The regression in build 18: advertising Gemini 3 Live's built-in googleSearch in setup makes a
# free-tier key fail session setup because Gemini 3 Google Search grounding is not available on the
# free tier. Keep the Live session on function calling only and route web lookup through web_search.
replace(
    'OpenVision/Services/GeminiLive/GeminiLiveService.swift',
    '''        DiagnosticLogger.shared.log("Gemini", "Sending session setup: AUDIO voice=\\(voiceName) + pt-BR JARVIS + Google Search")\n''',
    '''        DiagnosticLogger.shared.log("Gemini", "Sending session setup: AUDIO voice=\\(voiceName) + pt-BR JARVIS + native tools")\n'''
)

replace(
    'OpenVision/Services/GeminiLive/GeminiLiveService.swift',
    '''        INTERNET / CURRENT INFORMATION: Google Search grounding is available in this live session. Use it whenever the user asks to search/pesquisar na internet, or whenever the answer depends on current or time-sensitive information such as sports schedules/results, news, weather, prices, releases, current office-holders, or recent events. Do not say that you cannot browse when Google Search is available. For example, a question such as "qual é o próximo jogo do Corinthians?" should be grounded with Google Search before answering.\n''',
    '''        INTERNET / CURRENT INFORMATION: the native tool `web_search` is available. CALL `web_search` whenever the user asks to search/pesquisar na internet, or whenever the answer depends on current or time-sensitive information such as sports schedules/results, news, weather, prices, releases, current office-holders, or recent events. Do not answer current facts from stale model memory when `web_search` can verify them. For example, "qual é o próximo jogo do Corinthians?" must call `web_search` before answering.\n'''
)

replace(
    'OpenVision/Services/GeminiLive/GeminiLiveService.swift',
    '''        - copy_to_clipboard and search_docs as appropriate.\n''',
    '''        - copy_to_clipboard and search_docs as appropriate.\n        - web_search: search the current internet for time-sensitive/current information.\n'''
)

old_tools = '''    /// Build tool declarations: the on-device productivity tools (timers, reminders, calendar,\n    /// notes, clipboard, device status). Gemini nests function declarations under\n    /// `tools: [{functionDeclarations:[…]}]`.\n    private func buildToolDeclarations() -> [[String: Any]] {\n        // Gemini 3.1 Flash Live supports combining built-in Google Search grounding with our\n        // synchronous native function tools in the SAME Live session. This is what lets JARVIS\n        // answer time-sensitive questions (sports schedules, current news, prices, etc.) instead\n        // of falling back to stale model knowledge or claiming it cannot browse.\n        [\n            ["googleSearch": [:] as [String: Any]],\n            ["functionDeclarations": NativeToolRegistry.shared.geminiDeclarations]\n        ]\n    }\n'''
new_tools = '''    /// Build tool declarations for the Live voice session. Keep the session itself on custom\n    /// function calling only: Gemini 3 Google Search grounding is paid-tier-only, so advertising\n    /// googleSearch here breaks setup for the project's free-tier API key. Current-information\n    /// requests are handled by the native `web_search` bridge instead.\n    private func buildToolDeclarations() -> [[String: Any]] {\n        [["functionDeclarations": NativeToolRegistry.shared.geminiDeclarations]]\n    }\n'''
replace('OpenVision/Services/GeminiLive/GeminiLiveService.swift', old_tools, new_tools)

# Surface server-side setup errors in Diagnostics instead of collapsing everything into generic
# "backend failed" after the setup timeout.
replace(
    'OpenVision/Services/GeminiLive/GeminiLiveService.swift',
    '''        // Setup complete\n        if json["setupComplete"] != nil {\n            isSetupComplete = true\n            DiagnosticLogger.shared.log("Gemini", "Received setupComplete")\n            return\n        }\n\n        // Server content (audio, text, etc.)\n''',
    '''        // Setup complete\n        if json["setupComplete"] != nil {\n            isSetupComplete = true\n            DiagnosticLogger.shared.log("Gemini", "Received setupComplete")\n            return\n        }\n\n        // API errors can arrive as a root-level WebSocket event during setup. Older builds ignored\n        // these and later displayed only a generic backend failure, hiding the actual cause.\n        if let apiError = json["error"] as? [String: Any] {\n            let message = (apiError["message"] as? String) ?? "Unknown Gemini API error"\n            lastError = message\n            DiagnosticLogger.shared.log("Gemini", "Server API error: \\(message)")\n            print("[GeminiLive] Server API error: \\(message)")\n            return\n        }\n\n        // Server content (audio, text, etc.)\n'''
)

# Build number.
replace('project.yml', '    CURRENT_PROJECT_VERSION: "18"\n', '    CURRENT_PROJECT_VERSION: "19"\n')

# Build notes.
notes = Path('JARVIS_BUILD_NOTES.md')
text = notes.read_text()
header = '# Projeto JARVIS build notes\n\n'
if not text.startswith(header):
    raise SystemExit('Unexpected build notes header')
b19 = '''## Build 19\n\n- Fixed build 18 backend regression for free-tier Gemini keys.\n- Removed built-in Gemini 3 Google Search grounding from the Live session setup because current Gemini pricing marks Gemini 3 Search grounding unavailable on the free tier; this prevented setupComplete and surfaced as a generic backend failure.\n- Added native `web_search` tool that performs current-information lookup separately through `gemini-2.5-flash` + Google Search grounding, preserving the free Live voice session while still supporting current sports/news/web questions.\n- Added explicit diagnostics for root-level Gemini WebSocket API errors so future setup failures expose their actual server message.\n- App build number is 19.\n\n'''
notes.write_text(header + b19 + text[len(header):])

# Remove one-shot helper files from the resulting source commit.
Path('.github/workflows/apply-build19-backend-fix.yml').unlink(missing_ok=True)
Path('scripts/apply_build19_backend_fix.py').unlink(missing_ok=True)
