# JARVIS Versioning and Build Documentation

## Purpose

Keep every distributed/tested JARVIS package traceable to the exact source and reason for the change.

JARVIS uses three identifiers that must not be confused:

- **Marketing version** — `MARKETING_VERSION`, shown as the app version (for example `2.10.0`).
- **iOS build number** — `CURRENT_PROJECT_VERSION`, identifying the packaged app build (for example `42`).
- **GitHub Actions run number** — CI execution number (for example `#177`). This is build infrastructure evidence, not the app build number.

## Policy from Build 43 onward

1. Every package distributed for physical testing gets a unique incremented `CURRENT_PROJECT_VERSION`.
2. A release note is created in `docs/releases/` for every distributed/tested app build.
3. The release note records the exact commit/merge SHA, branch, PR, relevant CI runs and validation state.
4. `MARKETING_VERSION` may remain unchanged across small iterations; the iOS build number still increments.
5. A marketing-version change is reserved for a meaningful product milestone/release decision; do not change it only because CI ran again.
6. GitHub Actions run numbers may increase many times for the same app build while CI is being fixed or re-run.
7. No release note may invent historical behavior. Backfill older versions only from verifiable Git/PR/Actions evidence.
8. Runtime-changing releases must record whether physical iPhone validation was performed before merge.
9. The canonical release record lives in this OpenVision repository. The JARVIS Dev Brain/Obsidian links to these records rather than maintaining a divergent copy.

## Required release-note fields

Each file should record:

```text
Marketing version
App build number
Release state
Change type
Reason for the version
Base branch
Feature/fix branch
PR
Head SHA
Merge SHA (when merged)
Relevant GitHub Actions runs
What changed
Why it changed
What works in this build
Known limitations
Automated validation
Physical validation
Artifact/IPA evidence when applicable
Previous version/build
Next planned work
```

## Change-type vocabulary

Use one primary type and optional secondary types:

- `Feature` — new user-visible or architectural capability.
- `Fix` — correction of an existing defect.
- `Hotfix` — urgent focused production/test correction.
- `Refactor` — internal restructuring intended to preserve behavior.
- `Infra` — CI/build/dependency/developer infrastructure.
- `Docs` — documentation/process only.
- `Mixed` — only when a package intentionally combines multiple categories and one cannot reasonably be primary.

## Naming convention

Release files:

```text
docs/releases/<marketing-version>-build<ios-build>.md
```

Example:

```text
docs/releases/2.10.0-build42.md
```

## Historical caveat for Build 42

Before this policy, `CURRENT_PROJECT_VERSION` was not incremented for every materially different package. Therefore **Build 42 is not a globally unique historical source identifier by itself**. Always pair the old build number with commit/PR/CI evidence.

The stable snapshot after Brain Core integration is documented as `2.10.0-build42.md` with merge commit `20f71cccf0eb6428b9e2a46355f2507a6ee6c698` and post-merge CI `#177`.

Starting with Build 43, one distributed package should map to one unique iOS build number.
