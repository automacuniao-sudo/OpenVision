# Decision: defer OpenAI integration in Retrieval + PromptContextBuilder

Date: 2026-09-09
Status: active product decision

## Decision

OpenAI is not an active backend target for the current Retrieval + PromptContextBuilder phase.

The shared Retrieval/PromptContextBuilder architecture remains backend-agnostic, but this PR should integrate the new durable Brain context with Gemini Live first. OpenAI integration is deferred until the user explicitly decides to use it again.

## Consequences

- Do not modify `OpenAIService.swift` for this phase.
- Do not make OpenAI tests or integration a merge/acceptance requirement for PR #22.
- Gemini Live is the active backend integration target for this phase.
- Brain/SQLite remains canonical and provider-neutral, so OpenAI can be added later without redesigning retrieval.
- OpenClaw remains outside the active scope of this PR unless separately approved.
- Physical iPhone validation is still required before merge because Gemini conversational runtime behavior changes.

This decision supersedes the OpenAI integration task in the original implementation plan for the current phase only.
