# CI Governance Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the PR-based JARVIS patch workflow runnable from the default branch, secure its inputs, remove the imminent Node 20 dependency, and execute a portable subset of unit tests on every JARVIS CI run.

**Architecture:** Keep `main` as the default branch and `jarvis-dev` as the protected product branch. Put the manual dispatcher on `main`; it always checks out `jarvis-dev` and opens a PR back to `jarvis-dev`. Harden the matching workflow on `jarvis-dev`, while the product CI gains a simulator-only test target containing only portable text logic and retains the existing device `build-for-testing` gate for the complete app test bundle.

**Tech Stack:** GitHub Actions YAML, Bash, XcodeGen, Swift 5.9/XCTest, Git.

**Spec:** User-approved findings from the 2026-09-01 ORCHESTRATOR audit; no separate design file.

## Global Constraints

- Never push directly to `main` or `jarvis-dev`; use the task branches and open PRs.
- `main` must not receive the 119 JARVIS product commits or become the product branch.
- The dispatcher must check out `jarvis-dev`, create `patch/<run_id>-<run_attempt>`, push that branch, and open a PR targeting `jarvis-dev`.
- GitHub expression inputs must enter shell commands only through `env`; no `${{ inputs.* }}` expression may appear inside a `run:` block.
- `patch_script` must be a basename ending in `.py`, with no slash, backslash, leading dot, whitespace, or `..`, and it must resolve to an existing regular file under `.github/patches`.
- Use `actions/checkout@v6` and `actions/upload-artifact@v7`.
- CI copy must state that the complete `JARVISTests` bundle is compiled but not executed.
- Execute portable tests on an iOS simulator without linking the JARVIS app, Meta DAT, MLX, audio, camera, or Bluetooth dependencies.
- Hardware/model/audio paths remain device-only and must be called out as unexecuted in CI.
- Do not change app runtime behavior beyond moving the pure `TextChunking` helper verbatim to its own file.

---

### Task 1: Default-branch patch dispatcher

**Files:**
- Create: `.github/workflows/apply-patch.yml` in `C:/Users/Kaue/AppData/Local/Temp/OpenVision-ci-main`

**Interfaces:**
- Consumes: patch scripts from `.github/patches` on `jarvis-dev` and the built-in `GITHUB_TOKEN`.
- Produces: a manually dispatchable workflow on the default branch that opens patch PRs against `jarvis-dev`.

- [ ] **Step 1: Record RED structural checks**

Run PowerShell assertions showing `.github/workflows/apply-patch.yml` is absent on the task branch and record the expected failure in the Implementation Report.

- [ ] **Step 2: Add the hardened dispatcher**

Use job-level environment variables for the three inputs. Validate non-empty commit/title values and validate the patch filename with a strict Bash regex plus a canonical-path containment check. Serialize runs with a non-cancelling concurrency group, use `actions/checkout@v6`, include `run_attempt` in the patch branch name, use shell variables in `git commit`/`gh pr create`, and describe the PR check as “compilacao dos testes portateis + compilacao completa para dispositivo”.

- [ ] **Step 3: Verify GREEN structurally**

Run `git diff --check` and PowerShell assertions for the exact branch/ref, action version, input indirection, validation, target PR branch, and absence of direct input expressions in `run` blocks.

- [ ] **Step 4: Commit**

Commit message: `ci: add secure default-branch patch dispatcher`.

---

### Task 2: JARVIS CI hardening and executable pure tests

**Files:**
- Modify: `.github/workflows/apply-patch.yml` in `C:/Users/Kaue/AppData/Local/Temp/OpenVision-ci-jarvis`
- Modify: `.github/workflows/build-ios.yml`
- Modify: `project.yml`
- Create: `JARVIS/Utilities/TextChunking.swift`
- Modify: `JARVIS/Views/VoiceAgent/VoiceAgentViewModel.swift`
- Modify: `JARVISTests/DocumentChunkingTests.swift`
- Modify: `JARVISTests/TextChunkingTests.swift`

**Interfaces:**
- Consumes: existing pure `TextChunking` and `DocumentChunking` implementations/tests.
- Produces: scheme `JARVISPureTests` that runs those tests on an iOS simulator without depending on target `JARVIS`; the existing `JARVISTests` device compilation gate remains intact.

- [ ] **Step 1: Record RED checks**

Show that the workflow still references `checkout@v4`/`upload-artifact@v4`, that `JARVISPureTests` is absent from `project.yml`, and that `TextChunking` is embedded in `VoiceAgentViewModel.swift`.

- [ ] **Step 2: Harden the jarvis dispatcher**

Make it behaviorally identical to Task 1’s dispatcher, including input validation, environment indirection, concurrency, `run_attempt`, `checkout@v6`, and accurate PR copy.

- [ ] **Step 3: Extract pure text logic verbatim**

Move only the existing `TextChunking` enum and its comments from `VoiceAgentViewModel.swift` into `JARVIS/Utilities/TextChunking.swift`. Do not change signatures or behavior.

- [ ] **Step 4: Make the two portable test files dual-target compatible**

Wrap `@testable import JARVIS` in `#if !JARVIS_PURE_TESTS` / `#endif` in `DocumentChunkingTests.swift` and `TextChunkingTests.swift`. Do not change assertions.

- [ ] **Step 5: Add the portable test target and scheme**

Add target `JARVISPureTests` as an unhosted iOS unit-test bundle containing exactly `JARVIS/Utilities/TextChunking.swift`, `JARVIS/Services/Documents/DocumentChunking.swift`, `JARVISTests/DocumentChunkingTests.swift`, and `JARVISTests/TextChunkingTests.swift`. Define compilation condition `JARVIS_PURE_TESTS`; it must have no dependency on target `JARVIS` or any package. Add scheme `JARVISPureTests` with that target in build/test.

- [ ] **Step 6: Update product CI**

Use `actions/checkout@v6` and `actions/upload-artifact@v7`. After XcodeGen, run `xcodebuild test` for scheme `JARVISPureTests` on an available iOS Simulator selected deterministically from `xcrun simctl list devices available` or a stable generic simulator destination supported by the runner. Retain and clearly label the existing `JARVISTests` `build-for-testing` step on `generic/platform=iOS`, then retain the unsigned app build and push-only artifact upload.

- [ ] **Step 7: Verify structurally**

Run `git diff --check`; assert the action majors, the two distinct test gates, lack of `JARVIS` dependency in `JARVISPureTests`, exact source list, conditional imports, and a single `TextChunking` definition.

- [ ] **Step 8: Commit**

Commit message: `ci: harden patch flow and run portable tests`.

---

## Required validation after push

- PR to `main`: GitHub recognizes `Apply Patch` on the default branch after merge; no workflow execution is possible before that merge.
- PR to `jarvis-dev`: `Build JARVIS iOS` must run on the PR and pass the portable simulator tests, complete device test compilation, and unsigned app build; IPA upload must remain skipped on PR events.
- Confirm `jarvis-dev` protection requires PRs and the `Build JARVIS iOS` check. If exact legacy protection settings remain inaccessible, report that limitation rather than claiming success.
- Confirm repository Actions setting allows `GITHUB_TOKEN` to create pull requests. If it cannot be inspected without an authenticated admin session, provide the exact post-merge verification step.
