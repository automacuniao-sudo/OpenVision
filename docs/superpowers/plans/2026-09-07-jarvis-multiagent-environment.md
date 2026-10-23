# JARVIS Multiagent Development Environment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `JARVIS — ORCHESTRATOR` the normal single user-facing development entry point, backed by DEVELOPER, LEAD/REVIEWER, QA/BUILD, and the shared `JARVIS-DEV-BRAIN`, with `jarvis-dev` as the stable product base.

**Architecture:** Governance lives in `automacuniao-sudo/OpenVision`; durable development memory lives in `automacuniao-sudo/JARVIS-DEV-BRAIN`. ORCHESTRATOR is the workflow controller and single canonical Brain writer; delegated roles return structured reports. The workflow selects AUTOMATED MODE only when real delegation exists and otherwise produces explicit manual handoffs.

**Tech Stack:** Markdown governance files, Git/GitHub branches and worktrees, Codex agent/subagent capabilities, GitHub Actions/CI, Obsidian over the `JARVIS-DEV-BRAIN` clone.

**Spec:** `docs/superpowers/specs/2026-09-07-jarvis-multiagent-environment-design.md`

## Global Constraints

- Stable JARVIS product base is exactly `jarvis-dev`; normal product task branches/worktrees derive from current `origin/jarvis-dev`.
- `main` is not the normal base for JARVIS product work.
- Merge into `jarvis-dev` requires explicit human approval for that merge.
- `JARVIS-DEV-BRAIN/main` is the canonical development-memory branch.
- ORCHESTRATOR is the only normal-flow writer of canonical Dev Brain state.
- DEVELOPER, LEAD/REVIEWER, and QA/BUILD return structured reports and do not directly modify canonical Brain state.
- Never claim delegation unless the session exposes real delegation/subagent capabilities.
- No runtime Swift/SwiftUI/audio/MLX/Meta DAT behavior may change in this implementation.
- No API keys, passwords, tokens, signing material, provisioning secrets, or credentials may be persisted.
- No force-push or destructive shared-history rewrite.
- CI/build evidence and physical-device evidence must never be invented.

---

### Task 1: Align OpenVision governance with `jarvis-dev` and four official roles

**Files:**
- Modify: `AGENTS.md`
- Modify: `.agents/ORCHESTRATOR.md`
- Modify: `.agents/LEAD.md`
- Modify: `.agents/DEVELOPER.md`
- Create: `.agents/QA.md`

**Interfaces:**
- Consumes: the approved design spec and current role files.
- Produces: authoritative role contracts used by `docs/AI_WORKFLOW.md`, Codex chats, and delegated workers.

- [ ] **Step 1: Verify the task branch is isolated and based on `jarvis-dev`**

Run:

```bash
git fetch origin --prune
git status --short
git branch --show-current
git merge-base --is-ancestor origin/jarvis-dev HEAD
```

Expected:
- working tree is clean before edits;
- branch is not `main` and not `jarvis-dev`;
- `git merge-base --is-ancestor` exits `0`.

- [ ] **Step 2: Update `AGENTS.md` base-branch and role rules**

Make these exact semantic changes:

- replace the two-role statement with four official roles: ORCHESTRATOR, DEVELOPER, LEAD/REVIEWER, QA/BUILD;
- state that normal JARVIS development branches/worktrees derive from current `origin/jarvis-dev`;
- state that neither `main` nor `jarvis-dev` is an implementation workspace;
- require explicit human approval before merge into `jarvis-dev`;
- identify `JARVIS-DEV-BRAIN/main` as the development-memory source of truth;
- state that ORCHESTRATOR is the only normal-flow canonical Brain writer;
- update the mandatory flow to include independent LEAD/REVIEWER and QA/BUILD stages before `ready_for_human`;
- preserve existing risk guidance for audio, concurrency, MLX, Gemini Live, Meta DAT, and physical-device validation.

- [ ] **Step 3: Update `.agents/ORCHESTRATOR.md`**

The file must require the ORCHESTRATOR to:

```text
startup → daily-briefing → verify origin/jarvis-dev → classify/investigate → active task → Task Brief
→ detect AUTOMATED vs MANUAL FALLBACK
→ DEVELOPER → LEAD/REVIEWER → QA/BUILD
→ PR/CI as appropriate → ready_for_human
→ end-session
```

Also require:

- Brain reads: `JARVIS-DEV-BRAIN/AGENTS.md`, `00-Dashboard.md`, `_memory/current-state.md`, `_memory/roadmap.md`, relevant active task;
- single-writer Brain semantics;
- no fake delegation;
- no direct implementation merely to skip a delegated round when real delegation exists;
- PR target `jarvis-dev`;
- explicit human approval before merge/release.

- [ ] **Step 4: Update `.agents/LEAD.md` and `.agents/DEVELOPER.md`**

For LEAD/REVIEWER:

- make independent review the normal delegated role;
- consume Task Brief + Implementation Report + diff/commits + test evidence;
- return exactly `APPROVED` or `CHANGES_REQUIRED`;
- prohibit canonical Brain writes and merge authorization.

For DEVELOPER:

- require task branch/worktree derived from `jarvis-dev`;
- prohibit direct work on `main` or `jarvis-dev`;
- consume only task-relevant Brain knowledge when supplied;
- prohibit canonical Brain writes;
- preserve the current Implementation Report fields and self-review requirements.

- [ ] **Step 5: Create `.agents/QA.md` with a complete QA Report contract**

The new role must read the Task Brief acceptance criteria, LEAD verdict, branch/PR/commit identity, CI/test evidence, version/build identity when relevant, and hardware requirements.

Its verdict must be exactly one of:

```text
PASS
FAIL
PHYSICAL_TEST_REQUIRED
```

Its report must include:

```markdown
### QA Report
**Verdict**
`PASS | FAIL | PHYSICAL_TEST_REQUIRED`

**Commit / PR**
`<identity>`

**CI / checks**
- `<check>` → `<result>`

**Build / tests**
- `<command or evidence>` → `<result>`

**Version / artifact**
- `<version/build/artifact or not-applicable>`

**Missing validation**
- `<none or exact missing evidence>`

**Physical test procedure**
1. `<exact step when required>`

**Risks / observations**
- `<finding>`
```

State explicitly that QA never claims iPhone/Meta-glasses validation without supplied evidence and never edits canonical Brain state.

- [ ] **Step 6: Run governance static checks**

Run:

```bash
rg -n "HEAD atual de `main`|partir do HEAD atual de `main`|PR.*para `main`|merge em `main`" AGENTS.md .agents docs/AI_WORKFLOW.md
rg -n "jarvis-dev|JARVIS-DEV-BRAIN|QA / BUILD|QA/BUILD|AUTOMATED MODE|MANUAL FALLBACK MODE" AGENTS.md .agents
```

Expected after Task 1:
- stale statements that make `main` the normal JARVIS task base are gone from edited role/governance files;
- `jarvis-dev`, Dev Brain, QA, and both delegation modes are present where required;
- references that merely explain that `main` exists are allowed only if they do not define it as the task base or merge target.

- [ ] **Step 7: Review product diff and prove runtime code is untouched**

Run:

```bash
git diff --name-only origin/jarvis-dev...HEAD
git diff --check
```

Expected changed files at this checkpoint are governance/docs only; no path under `OpenVision/` or `OpenVisionTests/` appears.

- [ ] **Step 8: Commit Task 1**

```bash
git add AGENTS.md .agents/ORCHESTRATOR.md .agents/LEAD.md .agents/DEVELOPER.md .agents/QA.md
git commit -m "docs: formalize JARVIS multiagent roles"
```

---

### Task 2: Rewrite the documented Codex workflow around the ORCHESTRATOR

**Files:**
- Modify: `docs/AI_WORKFLOW.md`

**Interfaces:**
- Consumes: role contracts from Task 1.
- Produces: one operator-facing setup/runbook for the four fixed Codex chats and automated/fallback execution.

- [ ] **Step 1: Replace the old `main`-based flow with the approved four-stage pipeline**

Document this normal path exactly in meaning:

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

The PR target and task base must be `jarvis-dev`.

- [ ] **Step 2: Document the four fixed Codex chat names and startup contracts**

Use these names:

```text
JARVIS — ORCHESTRATOR
JARVIS — DEVELOPER
JARVIS — LEAD / REVIEWER
JARVIS — QA / BUILD
```

For the ORCHESTRATOR startup contract, require reads of both repositories and automatic `daily-briefing` before a meaningful task. For the other roles, document their bounded inputs and the prohibition on canonical Brain writes.

- [ ] **Step 3: Document AUTOMATED MODE capability detection**

State that AUTOMATED MODE is permitted only if the current session can genuinely:

1. spawn/dispatch a worker or subagent;
2. provide isolated task/context;
3. receive its result;
4. send follow-up work, preferably to the same worker for corrections.

Otherwise use MANUAL FALLBACK MODE and provide the exact next handoff for the relevant dedicated chat.

- [ ] **Step 4: Replace the worktree example with `jarvis-dev` as the base**

Document commands equivalent to:

```bash
git fetch origin --prune
git switch jarvis-dev
git pull --ff-only origin jarvis-dev
git worktree add ../OpenVision-task -b ai/YYYY-MM-DD-task-slug jarvis-dev
```

Also state that actual agent execution should confirm `origin/jarvis-dev` is the expected current base before creating the task branch.

- [ ] **Step 5: Document the fix loop and QA gate**

Required semantics:

```text
LEAD CHANGES_REQUIRED → same DEVELOPER corrects → LEAD re-review
LEAD APPROVED → QA/BUILD
QA FAIL → correction/review loop
QA PHYSICAL_TEST_REQUIRED → exact test steps to user
QA PASS → ready_for_human
```

CI and CodeRabbit remain additional layers, not substitutes for LEAD/QA.

- [ ] **Step 6: Run documentation checks**

Run:

```bash
rg -n "OpenVision — ORCHESTRATOR|JARVIS — ORCHESTRATOR|JARVIS — DEVELOPER|JARVIS — LEAD / REVIEWER|JARVIS — QA / BUILD" docs/AI_WORKFLOW.md
rg -n "jarvis-dev|AUTOMATED MODE|MANUAL FALLBACK MODE|PHYSICAL_TEST_REQUIRED|ready_for_human" docs/AI_WORKFLOW.md
rg -n "partir do HEAD atual de `main`|worktree.* main$|aprovação humana.*main" docs/AI_WORKFLOW.md
```

Expected:
- all new fixed chat names and mode/gate terms are present;
- the last command returns no stale rule that makes `main` the normal base/merge target.

- [ ] **Step 7: Commit Task 2**

```bash
git add docs/AI_WORKFLOW.md
git commit -m "docs: document ORCHESTRATOR-first Codex workflow"
```

---

### Task 3: Extend JARVIS-DEV-BRAIN for single-writer orchestration and standardized handoffs

**Files:**
- Modify in `automacuniao-sudo/JARVIS-DEV-BRAIN`: `AGENTS.md`
- Modify in `automacuniao-sudo/JARVIS-DEV-BRAIN`: `_knowledge/Brain-Workflows.md`
- Modify in `automacuniao-sudo/JARVIS-DEV-BRAIN`: `_templates/task.md`
- Create in `automacuniao-sudo/JARVIS-DEV-BRAIN`: `_templates/review-verdict.md`
- Create in `automacuniao-sudo/JARVIS-DEV-BRAIN`: `_templates/qa-report.md`
- Create in `automacuniao-sudo/JARVIS-DEV-BRAIN`: `_tasks/active/Multiagent-Environment.md`

**Interfaces:**
- Consumes: role contracts and task-state machine in the approved spec.
- Produces: canonical Brain rules/templates used by ORCHESTRATOR while delegated roles remain report-only.

- [ ] **Step 1: Synchronize the Brain before editing**

Run from the local Brain clone:

```bash
git fetch origin --prune
git switch main
git pull --ff-only origin main
git status --short
```

Expected: clean `main`. If local changes exist, stop and reconcile; do not stash/discard blindly.

- [ ] **Step 2: Update Brain `AGENTS.md` with single-writer role policy**

Add these exact rules in meaning:

- ORCHESTRATOR performs `daily-briefing` at task/session start;
- ORCHESTRATOR is the only normal-flow canonical writer;
- DEVELOPER, LEAD/REVIEWER, and QA/BUILD return reports only;
- reports are promoted only when durable and verified;
- code truth remains `OpenVision/jarvis-dev`; Brain truth remains `JARVIS-DEV-BRAIN/main`;
- no chain-of-thought, secrets, giant logs, or speculative state.

- [ ] **Step 3: Extend `_knowledge/Brain-Workflows.md`**

Define the task lifecycle:

```text
planned → in_progress → review → qa → ready_for_human → merged
```

and side states:

```text
changes_required
blocked
cancelled
```

Document who may transition state (ORCHESTRATOR) and when `end-session` promotes state, ADRs, builds, learnings, handoffs, and sessions.

- [ ] **Step 4: Upgrade `_templates/task.md`**

Use this frontmatter contract:

```yaml
---
type: task
status: planned
date: YYYY-MM-DD
project: JARVIS
related_repo: automacuniao-sudo/OpenVision
base_branch: jarvis-dev
branch: null
pr: null
---
```

Keep sections for Objective, Branch/worktree, Acceptance Criteria, Evidence, Blockers, and Handoff. Add a short `State history` section so ORCHESTRATOR can append verified transitions without rewriting prior evidence.

- [ ] **Step 5: Create `_templates/review-verdict.md`**

Use this structure:

```markdown
---
type: review-verdict
status: draft
project: JARVIS
---

# Review Verdict — title

## Verdict
`APPROVED | CHANGES_REQUIRED`

## Inputs reviewed
- Task Brief:
- Implementation Report:
- Commit/diff:
- Test evidence:

## Findings
- Severity:
- File/location:
- Problem:
- Consequence:
- Expected correction:

## Remaining manual risks
- None recorded.
```

- [ ] **Step 6: Create `_templates/qa-report.md`**

Use this structure:

```markdown
---
type: qa-report
status: draft
project: JARVIS
---

# QA Report — title

## Verdict
`PASS | FAIL | PHYSICAL_TEST_REQUIRED`

## Commit / PR

## CI / checks

## Build / tests

## Version / artifact

## Missing validation

## Physical test procedure

## Risks / observations
```

- [ ] **Step 7: Create the active Brain task for this environment implementation**

Create `_tasks/active/Multiagent-Environment.md` with:

```yaml
---
type: task
status: in_progress
date: 2026-09-07
project: JARVIS
related_repo: automacuniao-sudo/OpenVision
base_branch: jarvis-dev
branch: docs/jarvis-multiagent-environment
pr: null
---
```

Its acceptance criteria must mirror the spec success criteria: new ORCHESTRATOR session restores state from Brain; `jarvis-dev` is recognized as base; four role contracts work; single-writer policy is respected; automated/fallback behavior is truthful; no runtime changes; no secrets.

- [ ] **Step 8: Validate Brain diff and secret hygiene**

Run:

```bash
git diff --check
git grep -n -I -E "(api[_-]?key|secret|password|token|BEGIN (RSA|OPENSSH|PRIVATE) KEY)" -- .
```

Expected: any matches are documentation-only references; no actual credentials or private-key material.

- [ ] **Step 9: Commit and push the Brain changes**

```bash
git add AGENTS.md _knowledge/Brain-Workflows.md _templates/task.md _templates/review-verdict.md _templates/qa-report.md _tasks/active/Multiagent-Environment.md
git commit -m "docs: formalize multiagent Brain workflow"
git push origin main
```

Do not force-push.

---

### Task 4: Perform a static cross-repository governance review

**Files:**
- Review only: all files changed by Tasks 1–3

**Interfaces:**
- Consumes: updated product governance and Brain governance.
- Produces: evidence that the two repositories agree on roles, base branch, handoffs, task states, and memory ownership before Codex behavioral validation.

- [ ] **Step 1: Verify source-of-truth consistency**

Confirm both repositories state exactly:

```text
Product code truth = automacuniao-sudo/OpenVision / jarvis-dev
Development memory truth = automacuniao-sudo/JARVIS-DEV-BRAIN / main
Canonical Brain writer = ORCHESTRATOR
```

- [ ] **Step 2: Verify role and verdict vocabulary**

Search both repositories for:

```bash
rg -n "ORCHESTRATOR|DEVELOPER|LEAD / REVIEWER|LEAD/REVIEWER|QA / BUILD|QA/BUILD|APPROVED|CHANGES_REQUIRED|PHYSICAL_TEST_REQUIRED|ready_for_human"
```

Expected: role names and verdicts are semantically consistent; no competing QA verdict vocabulary exists.

- [ ] **Step 3: Verify stale `main` workflow rules are gone from OpenVision governance**

Run from OpenVision:

```bash
rg -n "HEAD atual de `main`|partir do HEAD atual de `main`|PR.*para `main`|merge em `main`" AGENTS.md .agents docs/AI_WORKFLOW.md
```

Review every hit. Expected: no hit instructs normal JARVIS tasks or PRs to target `main`.

- [ ] **Step 4: Verify no runtime files changed**

Run from OpenVision:

```bash
git diff --name-only origin/jarvis-dev...HEAD
```

Expected paths are limited to:

```text
AGENTS.md
.agents/ORCHESTRATOR.md
.agents/LEAD.md
.agents/DEVELOPER.md
.agents/QA.md
docs/AI_WORKFLOW.md
docs/superpowers/specs/2026-09-07-jarvis-multiagent-environment-design.md
docs/superpowers/plans/2026-09-07-jarvis-multiagent-environment.md
```

No path under `OpenVision/`, `OpenVisionTests/`, `project.yml`, or build workflows may appear.

- [ ] **Step 5: Run whitespace/patch validation**

```bash
git diff --check origin/jarvis-dev...HEAD
```

Expected: no whitespace errors.

- [ ] **Step 6: Commit any review-only documentation correction if required**

Only if Steps 1–5 reveal a documentation inconsistency, fix that inconsistency and commit it with:

```bash
git add <only-the-corrected-governance-files>
git commit -m "docs: align multiagent governance contracts"
```

If no correction is required, do not create an empty commit.

---

### Task 5: Validate the workflow in a fresh Codex ORCHESTRATOR session

**Files:**
- No product runtime files should be edited by this validation.
- Brain may be updated only by the ORCHESTRATOR under its new rules.

**Interfaces:**
- Consumes: completed governance contracts from Tasks 1–4.
- Produces: behavioral evidence for startup context recovery, mode detection, role handoffs, and `jarvis-dev` base selection.

- [ ] **Step 1: Pull both repositories locally before the validation**

In the Codex Project `Jarvis`, ensure both folders are present and synchronized:

```powershell
cd C:\Users\Kaue\Documents\ChatGPT\Jarvis
git fetch origin --prune

git switch docs/jarvis-multiagent-environment
git pull --ff-only origin docs/jarvis-multiagent-environment

cd C:\Users\Kaue\Documents\ChatGPT\Jarvis-Brain
git pull --ff-only origin main
```

Expected: both repositories are available to the same Codex Project.

- [ ] **Step 2: Start a fresh `JARVIS — ORCHESTRATOR` chat using only repository/Brain instructions**

Prompt:

```text
Você é o JARVIS — ORCHESTRATOR. Execute seu startup contract usando apenas os arquivos do Project Jarvis e do JARVIS-DEV-BRAIN, sem usar histórico de outros chats. Faça o daily-briefing, identifique a base estável do produto e informe uma única vez se esta sessão está em AUTOMATED MODE ou MANUAL FALLBACK MODE. Não altere runtime nem faça merge.
```

Expected response must recover at least:

```text
stable product branch = jarvis-dev
stable app version = 2.10.0 (42)
Dev Brain = JARVIS-DEV-BRAIN/main
current development priority = multiagent environment until this validation closes
```

- [ ] **Step 3: Verify truthful delegation-mode detection**

If Codex exposes real subagent/delegation capability, expected result is `AUTOMATED MODE`; otherwise expected result is `MANUAL FALLBACK MODE` plus an explicit handoff instead of a claim that another agent was contacted.

Record the actual result in the active Brain task; do not fabricate the preferred mode.

- [ ] **Step 4: Run a no-runtime-change handoff smoke test**

Ask the ORCHESTRATOR:

```text
Faça um smoke test do fluxo multiagente usando apenas a revisão desta própria configuração de governança. Não altere arquivos de runtime. O DEVELOPER deve produzir um Implementation Report sobre a branch atual; o LEAD/REVIEWER deve produzir APPROVED ou CHANGES_REQUIRED; o QA/BUILD deve produzir PASS, FAIL ou PHYSICAL_TEST_REQUIRED. Pare antes de qualquer merge.
```

Expected:
- DEVELOPER output matches the Implementation Report contract;
- LEAD/REVIEWER uses exactly `APPROVED` or `CHANGES_REQUIRED`;
- QA/BUILD uses exactly `PASS`, `FAIL`, or `PHYSICAL_TEST_REQUIRED`;
- no agent directly edits canonical Brain state except ORCHESTRATOR;
- no runtime file changes are introduced.

- [ ] **Step 5: Verify task branch ancestry**

From OpenVision, run:

```bash
git merge-base --is-ancestor origin/jarvis-dev HEAD
git log -1 --oneline origin/jarvis-dev
```

Expected: ancestry command exits `0`; reported base matches the known current `origin/jarvis-dev` used when the task branch was created.

- [ ] **Step 6: Record behavioral evidence in the Brain**

ORCHESTRATOR updates `_tasks/active/Multiagent-Environment.md` with:

- startup recovery result;
- actual delegation mode detected;
- DEVELOPER report result;
- LEAD verdict;
- QA verdict;
- branch ancestry evidence;
- confirmation that no runtime files changed.

Create a concise `_sessions/YYYY-MM-DD-multiagent-environment-validation.md` only if the validation is meaningful and evidence-backed.

---

### Task 6: Prepare the governance PR and close the setup only after technical validation

**Files:**
- OpenVision branch: governance/spec/plan files only
- Brain: `_tasks/active/Multiagent-Environment.md`, then `_tasks/completed/Multiagent-Environment.md` only after evidence supports completion
- Brain: `00-Dashboard.md`, `_memory/current-state.md`, `_memory/roadmap.md` only if real state changes warrant it

**Interfaces:**
- Consumes: static review and fresh-session Codex validation evidence.
- Produces: reviewable PR against `jarvis-dev` and durable Brain completion state; no merge occurs without human approval.

- [ ] **Step 1: Push the OpenVision governance branch**

```bash
git push -u origin docs/jarvis-multiagent-environment
```

- [ ] **Step 2: Open a PR against `jarvis-dev`**

PR title:

```text
docs: formalize JARVIS multiagent development workflow
```

PR body must include:

```markdown
## Objective
Make JARVIS — ORCHESTRATOR the normal single development entry point backed by DEVELOPER, LEAD/REVIEWER, QA/BUILD, and JARVIS-DEV-BRAIN.

## Scope
Governance/documentation only. No runtime product behavior changed.

## Base
`jarvis-dev`

## Validation
- static governance consistency checks
- no runtime files changed
- fresh Codex ORCHESTRATOR startup test
- delegation-mode truthfulness test
- DEVELOPER / LEAD / QA handoff smoke test
- Brain single-writer behavior confirmed

## Merge policy
Do not merge without explicit human approval.
```

- [ ] **Step 3: Check CI/PR review evidence**

Inspect CI and CodeRabbit if they run on documentation-only changes. Resolve any meaningful governance finding through the same review process. Do not claim CI is green without checking the actual PR commit.

- [ ] **Step 4: Mark Brain task `ready_for_human`**

Only after Tasks 1–5 and relevant PR checks pass, update the active Brain task:

```yaml
status: ready_for_human
```

Record PR identity and remaining human action. Do not mark `merged` yet.

- [ ] **Step 5: Stop for explicit human merge approval**

Report:

```text
Governance implementation validated and PR is ready for human decision.
No runtime code changed.
Merge into jarvis-dev has NOT been performed.
```

Do not merge merely because the PR is ready.

- [ ] **Step 6: After explicit human merge approval and successful merge, close Brain state**

After verifying the actual merge commit exists in `jarvis-dev`:

- move `_tasks/active/Multiagent-Environment.md` to `_tasks/completed/Multiagent-Environment.md`;
- set `status: merged` or completed equivalent with merge commit evidence;
- update `00-Dashboard.md` to make runtime Second Brain + PersonProfile the next product priority;
- update `_memory/current-state.md` to state that the multiagent environment is operational;
- update `_memory/roadmap.md` only to reflect the completed environment setup and next approved product work;
- run the Brain secret scan before final push.

Brain validation:

```bash
git diff --check
git grep -n -I -E "(api[_-]?key|secret|password|token|BEGIN (RSA|OPENSSH|PRIVATE) KEY)" -- .
git status --short
```

Expected: no real credential, clean final working tree after commit/push.

---

## Plan self-review

### Spec coverage

- Single ORCHESTRATOR user entry point: Tasks 1, 2, 5.
- Four official roles: Tasks 1, 2, 5.
- `jarvis-dev` base and PR target: Tasks 1, 2, 4, 5, 6.
- Dev Brain source of truth and single-writer policy: Tasks 1, 3, 4, 5, 6.
- Standard Task Brief / Implementation Report / Review Verdict / QA Report: Tasks 1, 3, 5.
- Task state machine: Task 3.
- `daily-briefing`, `braindump`, `end-session`: Tasks 1, 3, 5, 6.
- AUTOMATED/MANUAL FALLBACK truthfulness: Tasks 1, 2, 5.
- Fix loop and QA gate: Tasks 1, 2, 5.
- No runtime changes: Tasks 1, 4, 5, 6.
- Human merge authority: Tasks 1, 2, 6.
- Security/no secrets: Tasks 1, 3, 6.
- Cross-client behavioral validation: Task 5.

### Placeholder scan

No `TBD`, `TODO`, `implement later`, undefined helper, or open-ended code step is intentionally present. Template placeholder notation is used only inside explicit reusable Markdown template examples and does not represent an unresolved implementation requirement.

### Contract consistency

The plan consistently uses:

```text
Base: jarvis-dev
Brain: JARVIS-DEV-BRAIN/main
Canonical writer: ORCHESTRATOR
Review: APPROVED | CHANGES_REQUIRED
QA: PASS | FAIL | PHYSICAL_TEST_REQUIRED
Ready state: ready_for_human
Human merge gate: required
```
