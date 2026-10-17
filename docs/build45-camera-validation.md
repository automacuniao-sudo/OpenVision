# Build 45 — camera routing and capture ownership

Build 44 diagnostics establish registration/compatibility and a received JPEG photo,
but do not establish raw video delivery or conversion. The app's normal Gemini
conversation routed glasses frames to GeminiVision instead of its connected
GeminiLive service. One-shot capture also stopped streams opened by another mode.

Build 45 routes frames to the active live service (dedicated mode first, then the
normal Gemini conversation), throttles before JPEG encoding, preserves borrowed
streams, and distinguishes SDK `.streaming` readiness from a requested start.
Captures use timestamps without clearing shared frame/photo caches. The existing
four-second frame budget starts after readiness; readiness has a separate bounded
four-second check. A still is requested when raw frames are not recent, but a slow
still may arrive after the budget; this is not proof of reliable photo transport.
No timeout increase, SDK upgrade, audio-engine change, or Brain change is included.

Default and requested glasses sources prefer glasses with phone rear fallback.
Only explicit phone/front/rear requests select a phone camera directly. Self-face
requests no longer implicitly select selfie. Gemini's camera_capture tool supplies
an awaited image before the function result and reports its actual source. Live
frames are suspended for that visual turn. Camera batches run in a tracked task
so remote/local interruption and tool cancellation can invalidate the capture;
socket, operation and stream identities reject stale work after replacement.

Local validation: Python configuration regression suite and diff whitespace checks.
CameraPolicyTests are wired into JARVISPureTests; Linux has no Swift compiler or
Xcode, so these and all changed iOS code require CI compilation/test validation.
No hardware success is claimed.

## Physical checks (2.10.0, Build 45)

1. With glasses connected, start a normal Gemini conversation. Ask “o que estou
   vendo?” with the phone pointed elsewhere. Verify glasses imagery and spoken answer.
2. Ask for a face-memory lookup during the conversation; confirm subsequent scene
   questions still work and the tool has not stopped the existing stream.
3. Say “use a câmera traseira do celular e descreva”; then request a front-camera
   image. Confirm the requested camera and reported source. Ask the next default
   scene question and confirm glasses resume.
4. Disconnect glasses and repeat a scene question. Confirm phone fallback is
   identified; denied phone permission must produce an honest capture failure.
5. Interrupt a camera request and immediately ask another question; disconnect /
   reconnect while a photo is pending. No stale image/result may enter the new turn.
6. Enter/exit dedicated live mode; verify destination restores appropriately.
7. Export diagnostics: Frames received/converted/conversionFailed, routed
   destination, Gemini video sent/failed, and capture actual source. No image bytes,
   keys or tokens are added to diagnostics. If raw counters remain zero, transport
   remains a separate unresolved hardware/SDK issue.
