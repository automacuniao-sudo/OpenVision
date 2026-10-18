# JARVIS Release / Build History

This directory is the canonical index of distributed and physically tested JARVIS app builds.

Read `../VERSIONING.md` first to distinguish:

- marketing version (`MARKETING_VERSION`);
- iOS app build (`CURRENT_PROJECT_VERSION`);
- GitHub Actions run number.

## Current verified baseline

| Marketing version | iOS build | Canonical source | CI evidence | Change | State |
|---|---:|---|---|---|---|
| `2.10.0` | `42` | `20f71cccf0eb6428b9e2a46355f2507a6ee6c698` | `#177` post-merge | Brain Core | Stable baseline |

## Policy

Starting with iOS Build 43, every package distributed for physical testing should have a unique build number and its own file here.

Historical backfill is allowed only where Git/PR/Actions evidence is sufficient. Do not infer features from an old build number alone.

## Files

- [`2.10.0-build42.md`](2.10.0-build42.md) — stable Brain Core baseline after PR #19 merge.
