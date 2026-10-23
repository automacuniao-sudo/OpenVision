# JARVIS Multiagent Development Environment — Design

Date: 2026-09-07
Status: Approved in chat, pending implementation plan
Base product branch: `jarvis-dev`
Product repository: `automacuniao-sudo/OpenVision`
Development memory repository: `automacuniao-sudo/JARVIS-DEV-BRAIN`

## 1. Objective

Create a stable multiagent development workflow in which the user normally interacts only with a single `JARVIS — ORCHESTRATOR` chat. The ORCHESTRATOR coordinates implementation, review, QA/build validation, pull-request preparation, and durable development memory without requiring the user to manually move the task between agents.

The design must work in two environments:

1. **AUTOMATED MODE** — the session exposes real subagent/delegation capabilities.
2. **MANUAL FALLBACK MODE** — the session cannot delegate, so the ORCHESTRATOR produces explicit handoffs for the user to move between dedicated Codex chats.

The system must never pretend that delegation happened when the environment does not provide real delegation.

## 2. Source-of-truth model

Two repositories have distinct responsibilities.

### Product source of truth

- Repository: `automacuniao-sudo/OpenVision`
- Stable JARVIS product branch: `jarvis-dev`
- Normal task branches and worktrees must derive from the current HEAD of `jarvis-dev`.
- `main` is not the normal base branch for JARVIS product work.
- Merge into `jarvis-dev` requires explicit human approval.

### Development-memory source of truth

- Repository: `automacuniao-sudo/JARVIS-DEV-BRAIN`
- Stable branch: `main`
- Obsidian is the human-facing UI for this memory repository.
- GitHub provides synchronization between Codex, ChatGPT, local Git, and Obsidian.
- The future runtime `JARVIS-BRAIN` is a different system and must not be mixed with `JARVIS-DEV-BRAIN`.

## 3. Official roles

The development workflow has four official roles.

### 3.1 ORCHESTRATOR

The ORCHESTRATOR is the normal user-facing entry point and workflow controller.

Responsibilities:

- read the Dev Brain at task start;
- verify the current product state;
- confirm `jarvis-dev` as the task base;
- classify and investigate the request;
- create or update the active task record;
- produce a self-contained Task Brief;
- detect whether real delegation is available;
- dispatch DEVELOPER, LEAD/REVIEWER, and QA/BUILD when possible;
- coordinate fix loops;
- open or update a PR after technical approval;
- consolidate durable outcomes into the Dev Brain;
- execute the `end-session` workflow for relevant sessions;
- stop for human approval before merge or release.

The ORCHESTRATOR is the only agent authorized to directly modify canonical Dev Brain state during the normal workflow.

### 3.2 DEVELOPER

The DEVELOPER implements the approved Task Brief in an isolated branch/worktree.

Responsibilities:

- read only the task-relevant product context;
- implement the minimum correct change;
- create or adjust tests;
- run available validations;
- perform self-review;
- return an Implementation Report.

The DEVELOPER must not:

- redefine architecture without returning the decision to the ORCHESTRATOR/LEAD;
- alter canonical Dev Brain state;
- merge into `jarvis-dev`;
- broaden scope silently.

### 3.3 LEAD / REVIEWER

The LEAD/REVIEWER evaluates the implementation independently from the DEVELOPER.

Responsibilities:

- compare implementation with the original Task Brief;
- inspect the diff and relevant code paths;
- validate root-cause correctness;
- inspect concurrency, audio, state, memory, lifecycle, streaming, and hardware risks when applicable;
- verify test quality and missing coverage;
- return `APPROVED` or `CHANGES_REQUIRED` with structured findings.

The LEAD/REVIEWER must not implement changes merely for convenience and must not modify canonical Dev Brain state.

### 3.4 QA / BUILD

QA/BUILD provides the final technical validation layer before the task is marked ready for human action.

Responsibilities:

- verify CI result and required checks;
- confirm build/test evidence;
- confirm app version/build number when relevant;
- verify artifacts when generated;
- identify validations that require a physical iPhone or Meta glasses;
- return one of: `PASS`, `FAIL`, or `PHYSICAL_TEST_REQUIRED`.

QA/BUILD must not modify canonical Dev Brain state.

## 4. Normal user experience

The intended daily experience is:

```text
USER
  ↓
JARVIS — ORCHESTRATOR
  ↓
DEVELOPER
  ↓
LEAD / REVIEWER
  ↓
QA / BUILD
  ↓
ORCHESTRATOR
  ↓
USER approval / physical test / merge decision
```

The user should not normally need to say "send this to the developer", "ask the lead to review", or "run QA".

Dedicated DEVELOPER, LEAD/REVIEWER, and QA/BUILD chats remain available for fallback, diagnostics, and isolated manual work.

## 5. Task-start context contract

### ORCHESTRATOR must read from `JARVIS-DEV-BRAIN`

- `AGENTS.md`
- `00-Dashboard.md`
- `_memory/current-state.md`
- `_memory/roadmap.md`
- the current file under `_tasks/active/`, when one exists
- task-specific `_knowledge/`, `_decisions/`, `_builds/`, or `_handoffs/` only when relevant

### ORCHESTRATOR must read from `OpenVision`

- `AGENTS.md`
- `.agents/ORCHESTRATOR.md`
- `.agents/LEAD.md`
- `.agents/DEVELOPER.md`
- `.agents/QA.md`
- `README.md`
- `docs/AI_WORKFLOW.md`
- architecture or code files required by the task

Before implementation, the ORCHESTRATOR verifies:

- product base is `jarvis-dev`;
- `origin/jarvis-dev` is current enough for the task;
- working state is known;
- the task branch/worktree is isolated;
- implementation is not occurring directly on `jarvis-dev` or `main`.

## 6. Context minimization for delegated agents

Agents should not receive the entire Brain by default.

### DEVELOPER receives

- role instruction;
- `AGENTS.md` and `.agents/DEVELOPER.md`;
- complete Task Brief;
- branch/worktree identity;
- relevant code/docs;
- selected Brain knowledge only when the task requires it.

### LEAD/REVIEWER receives

- role instruction;
- original Task Brief;
- Implementation Report;
- diff/commits;
- test evidence;
- relevant technical context.

### QA/BUILD receives

- Task Brief acceptance criteria;
- LEAD verdict;
- branch/PR/commit identity;
- CI and test evidence;
- expected version/build/artifact data;
- physical-test requirements when applicable.

This keeps contexts smaller, reduces accidental scope expansion, and makes handoffs reproducible.

## 7. Standard handoff contracts

### 7.1 ORCHESTRATOR → DEVELOPER: Task Brief

Required fields:

- Objective
- Current behavior
- Desired behavior
- Confirmed root cause or bounded hypothesis
- Relevant files/interfaces
- Numbered implementation plan
- Explicit non-goals
- Acceptance criteria
- Required validation
- Risks
- Branch/worktree

### 7.2 DEVELOPER → ORCHESTRATOR: Implementation Report

Required fields:

- Branch
- What changed
- Files changed
- Why the change solves the task
- Tests executed and results
- Tests not executed and reason
- Manual/physical testing required
- Risks/observations
- Self-review checklist
- Relevant commits/diff

### 7.3 LEAD/REVIEWER → ORCHESTRATOR: Review Verdict

Result must be exactly one of:

- `APPROVED`
- `CHANGES_REQUIRED`

For `CHANGES_REQUIRED`, every finding must include:

- severity;
- file/location;
- problem;
- consequence;
- expected correction.

### 7.4 QA/BUILD → ORCHESTRATOR: QA Report

Result must be exactly one of:

- `PASS`
- `FAIL`
- `PHYSICAL_TEST_REQUIRED`

The report records:

- CI/checks evaluated;
- build/test commands and evidence;
- version/build identity when relevant;
- artifacts when relevant;
- missing validation;
- exact physical test steps when hardware is required.

## 8. Task state machine in Dev Brain

Every active development task has a durable state.

Primary path:

```text
planned
  ↓
in_progress
  ↓
review
  ↓
qa
  ↓
ready_for_human
  ↓
merged
```

Additional states:

- `changes_required`
- `blocked`
- `cancelled`

A task note should contain at least:

```yaml
---
type: task
status: in_progress
project: JARVIS
base_branch: jarvis-dev
branch: ai/YYYY-MM-DD-task-slug
pr: null
---
```

State transitions are written to the Brain by the ORCHESTRATOR, not by delegated agents.

## 9. Dev Brain write policy

Canonical memory uses single-writer semantics during the development workflow.

### ORCHESTRATOR may update

- `_tasks/active/`
- `_tasks/completed/`
- `_sessions/`
- `_handoffs/`
- `_builds/`
- `_decisions/`
- `_learnings/`
- `_memory/current-state.md`
- `_memory/roadmap.md`
- `00-Dashboard.md`

Only when the information is durable, verified, and appropriate for the destination.

### DEVELOPER, LEAD/REVIEWER, and QA/BUILD

They return structured reports to the ORCHESTRATOR. They do not directly edit canonical Brain state in the normal flow.

### Brain synchronization guardrails

Before writing:

1. synchronize or verify the current `JARVIS-DEV-BRAIN/main` state;
2. inspect conflicting/newer remote changes;
3. modify only necessary memory files;
4. inspect the diff;
5. ensure no secret/credential is introduced;
6. commit and push without force-push.

No agent may overwrite newer Brain state merely to preserve a stale local snapshot.

## 10. `daily-briefing`, `braindump`, and `end-session`

### `daily-briefing`

Executed automatically by the ORCHESTRATOR when a new meaningful task/session starts.

Order:

1. Dashboard
2. current state
3. roadmap
4. active task
5. task-specific knowledge/decisions as needed

### `braindump`

Used when unstructured user/project information needs persistence. The ORCHESTRATOR classifies it before deciding whether it belongs in task state, knowledge, decision, build, learning, handoff, or nowhere.

### `end-session`

Executed by the ORCHESTRATOR after a meaningful work session.

Decision rules:

- Update `current-state.md` only when real project state changed.
- Create/update an ADR only for an approved architectural decision.
- Write `_builds/` only with actual build/test evidence.
- Update `_tasks/` when the task state changed.
- Write `_learnings/` only for reusable durable lessons.
- Write `_handoffs/` when cross-session continuation requires it.
- Create/update a session note for meaningful work.
- Never persist chain-of-thought, giant raw logs, discarded attempts, or credentials.

Discussion alone is not a state change.

## 11. Delegation-mode detection

At the start of the first task in a session, the ORCHESTRATOR inspects the capabilities actually exposed by the environment.

### AUTOMATED MODE

Use only when the session can genuinely:

- spawn or dispatch a worker/subagent;
- provide an isolated task/context;
- receive its result;
- send follow-up work, preferably to the same worker when correcting findings.

The ORCHESTRATOR announces `AUTOMATED MODE` once, then continues without asking permission between normal workflow stages.

### MANUAL FALLBACK MODE

If real delegation is unavailable, the ORCHESTRATOR announces `MANUAL FALLBACK MODE` once and provides the exact next handoff for one of the dedicated chats:

- `JARVIS — DEVELOPER`
- `JARVIS — LEAD / REVIEWER`
- `JARVIS — QA / BUILD`

The ORCHESTRATOR must never claim that it contacted another chat or agent when it did not.

## 12. Automated execution loop

When delegation exists:

```text
ORCHESTRATOR
  ↓ investigate + Task Brief
DEVELOPER
  ↓ Implementation Report
LEAD / REVIEWER
  ├─ CHANGES_REQUIRED → DEVELOPER correction → re-review
  └─ APPROVED
        ↓
QA / BUILD
  ├─ FAIL → correction/review loop
  ├─ PHYSICAL_TEST_REQUIRED → user receives exact test procedure
  └─ PASS
        ↓
ORCHESTRATOR → ready_for_human
```

The ORCHESTRATOR does not implement fixes itself merely to avoid another agent round when delegation is available.

## 13. Pull-request and merge policy

After LEAD approval and appropriate QA evidence, the ORCHESTRATOR may create or update a PR against `jarvis-dev`.

The PR must summarize:

- problem/objective;
- root cause or design rationale;
- solution;
- principal files;
- tests;
- unexecuted tests;
- manual/physical test procedure when applicable;
- risks.

CI and CodeRabbit are additional review layers and do not replace LEAD/QA review.

The ORCHESTRATOR may not merge into `jarvis-dev` without explicit human approval for that merge.

Release/publication actions also require explicit human approval.

## 14. Required governance changes during implementation

Implementation of this design is expected to update governance only; it must not change runtime product behavior.

Expected product-repository changes:

- update `AGENTS.md` so normal JARVIS work is based on `jarvis-dev`, not `main`;
- update `.agents/ORCHESTRATOR.md` with Dev Brain integration, single-writer memory rules, and `jarvis-dev` base;
- update `.agents/LEAD.md` to formalize reviewer-only handoff behavior;
- update `.agents/DEVELOPER.md` to formalize Brain read-only/no-canonical-write behavior and `jarvis-dev` base;
- add `.agents/QA.md`;
- update `docs/AI_WORKFLOW.md` to document the four-role automated/fallback pipeline;
- document fixed Codex chat names and their startup contracts;
- preserve existing runtime code unchanged.

Expected Brain-repository changes, if necessary:

- extend agent/workflow documentation so ORCHESTRATOR is the canonical writer;
- add templates for Review Verdict and QA Report if they materially improve reproducibility;
- record completion of the multiagent-environment setup once validated.

## 15. Failure and conflict handling

### Product repository conflict

If task-base state is ambiguous, stale, or dirty, the ORCHESTRATOR must resolve or surface the conflict before implementation.

### Brain conflict

If `JARVIS-DEV-BRAIN/main` moved since the ORCHESTRATOR last read it, the ORCHESTRATOR must re-read and reconcile rather than force overwriting.

### Agent disagreement

- DEVELOPER may challenge a Task Brief with evidence but cannot silently redesign it.
- LEAD/REVIEWER decides technical approval/rejection.
- Architectural ambiguity that changes approved scope returns to the user when necessary.

### CI failure

QA returns `FAIL`; the task cannot progress to `ready_for_human` solely because local tests passed.

### Hardware-only validation

QA returns `PHYSICAL_TEST_REQUIRED` and provides exact instructions. The system must not claim physical validation before the user supplies evidence.

## 16. Security and privacy guardrails

- No API keys, passwords, tokens, signing material, provisioning secrets, or credentials may be persisted in either repository.
- Dev Brain stores durable development context, not private chain-of-thought.
- Raw giant logs should not be persisted unless they are intentionally reduced to a relevant artifact with no secrets.
- No force-push or destructive history rewrite is part of the normal workflow.

## 17. Success criteria

The environment is considered implemented when all of the following are demonstrated:

1. A new ORCHESTRATOR session can recover current JARVIS state from the Dev Brain without relying on prior chat history.
2. The ORCHESTRATOR recognizes `jarvis-dev` as the stable product base.
3. A task receives a branch/worktree derived from `jarvis-dev`, not `main`.
4. The ORCHESTRATOR can select AUTOMATED MODE when real delegation exists and MANUAL FALLBACK MODE otherwise.
5. DEVELOPER returns a standardized Implementation Report.
6. LEAD/REVIEWER returns a standardized review verdict.
7. QA/BUILD returns `PASS`, `FAIL`, or `PHYSICAL_TEST_REQUIRED` with evidence.
8. Only the ORCHESTRATOR writes canonical Brain state in the normal workflow.
9. Task state transitions are recoverable from `_tasks/active/` without chat history.
10. `end-session` records durable changes without persisting chain-of-thought or secrets.
11. CI/build/hardware limitations are represented truthfully.
12. No runtime JARVIS behavior changes as a side effect of this governance implementation.
13. No merge into `jarvis-dev` occurs without explicit human approval.

## 18. Non-goals

This design does not implement:

- JARVIS runtime Second Brain;
- PersonProfile;
- Learning Engine;
- Router v1;
- OpenClaw work;
- Spotify;
- Ray-Ban hardware validation;
- autonomous merge or release;
- autonomous code self-modification outside the approved development workflow.

## 19. Recommended Codex chat names

Use these stable names in the `Jarvis` Codex Project:

- `JARVIS — ORCHESTRATOR`
- `JARVIS — DEVELOPER`
- `JARVIS — LEAD / REVIEWER`
- `JARVIS — QA / BUILD`

The ORCHESTRATOR is the normal point of contact. Other chats are fallback/diagnostic interfaces, not parallel sources of canonical project state.
