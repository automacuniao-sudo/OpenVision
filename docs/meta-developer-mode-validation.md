# Build 44: personal Meta glasses registration validation

## Cause and scope

Build 43's CI generated `MetaAppID = 0000000000`, kept the example ClientToken,
and left TeamID empty. This is partial attestation configuration, not a valid
personal developer configuration. Enabling Developer Mode in Meta AI does not
replace the configuration embedded in an installed IPA.

CI now copies `Config.developer.xcconfig`: MetaAppID, ClientToken and TeamID are
explicitly empty. The callback remains `jarvis://`, matching the registered
`jarvis` URL scheme. A validator checks the **built** Info.plist on every build,
before packaging, without logging credential values. This profile is only for
unsigned personal-development artifacts; production attestation/signing setup
is separate. Local production settings and the example configuration are unchanged.

Evidence:
- [Meta's official getting-started guide](https://github.com/facebook/meta-wearables-dat-ios/blob/bbae597cd1c748cd29b9375a1624a8d75b1c9e14/plugins/mwdat-ios/skills/getting-started/SKILL.md)
  documents empty MetaAppID as no-app-ID developer mode, skipping attestation.
- The pinned 0.9.0 SDK binary (tag commit `9b1b83d791dfebff7afd452e924a256819094b64`)
  contains an explicit partial-attestation diagnostic for missing ClientToken/TeamID.
  Static inspection supports the cause; it is not a successful registration test.

SDK stays pinned at **0.9.0**. The user's Meta AI About screen shows DAT
**1.0.0.0**; that does not establish the embedded iOS SDK version or prove a
compatibility failure. Compatibility still requires a physical test. No SDK,
audio, Brain, Retrieval or registration API changes are included.

This correction intentionally starts from Build 43 / Retrieval commit `a7a329c`,
instead of main, to preserve the user's pending Retrieval validation. It remains
part of PR #22 validation, without merging that PR. Its existing controlled
packaging exception is not expanded and must still be removed before merge.
`workflow_dispatch` can also generate an IPA where the workflow is available.

## Verification

Run `python3 -m unittest discover -s scripts/tests -v`.
The tests cover resolved developer config, Build 43's malformed configuration,
nonempty/unresolved credentials and callback mismatches. CI also runs existing
iOS simulator tests, device build-for-testing, then the built-plist validator.
Linux checks do not establish an iOS build or successful hardware registration.

## Test on the iPhone and glasses

1. Install the newly generated **2.10.0 (44)** IPA using the usual signing method.
   Keep the same signing account/bundle identity where possible to preserve data;
   do not uninstall first. Confirm the displayed build number before testing.
2. Keep Developer Mode enabled in Meta AI. Turn on and connect the glasses there.
3. In JARVIS, open **Glasses → Register App**. Expect the Meta AI authorization
   flow instead of the invalid/incomplete toolkit configuration error.
4. Complete authorization and return to JARVIS. If offered, use
   **Install/Update Glasses App**, then connect and request camera access.
5. Test audio input/output and “o que estou vendo?” with the phone camera pointed
   elsewhere. Confirm the image is from the glasses. Recheck Retrieval separately:
   save a preference, restart the session and ask about it.
6. On failure capture the exact error, build number, Meta AI/DAT version, and
   `[Glasses]` logs. Do not share tokens or API keys. Registration, callback,
   device readiness and camera streaming are separate checkpoints.

Adjacent issue deferred: the current app plist lacks the local-network usage and
Bonjour declarations in the latest Meta guide for Wi-Fi transport. This change
only fixes registration credentials; if camera transport later fails, investigate
that separately against the pinned SDK rather than treating it as proof this
registration fix failed.
