# iOS foundation implementation evidence

Track 1 of `docs/milestones/M5-ios.md`, implemented on local worker branch
`koi/ios-foundation-f786a1` based on `chirp/ios`.

Code commits:

- `7736656` — portable ChirpCore plus complete shared package, initial models,
  secure storage, history, encrypted bridge, tests and API usage contract.
- `5419f3b` — Darwin public-header C module, atomic history Use raw update,
  race/tamper tests, no-write reconciliation and real notification cancellation test.

Only `mac/**`, `ios/Shared/**` and this review document were changed. No push,
PR, main merge, device install, Apple ID access or persistent service was used.
API coordination was sent early and iterated through `koi msg` with `ios-app`,
`ios-keyboard` and `chirp-ios-orc`; final usage contract is
`ios/Shared/README.md`.

## Delivered behavior

`ChirpCore` declares iOS 18/macOS 15 support. Carbon hotkeys/raw offer and
AppKit insertion implementations are guarded; public Mac APIs remain available.
The iOS dependency continues to use the original codec, StreamSession,
PCMConverter, profiles, styles and word timing types. SwiftPM builds the library
product without selecting the Mac executable/UI products for iOS consumers.

`ClientMessage.start` now preserves an explicitly present empty or whitespace
`correction_prompt`; nil still omits it. The Mac preference editor's existing
blank-edit policy remains unchanged. Prompt and legacy instruction clamping
counts Unicode scalars to match Python `len`, without splitting graphemes;
family emoji/combining-mark tests cover the mismatch. The parent added `ios`
to the server's accepted `client` values; iOS must use that updated server.

`ChirpIOSCore` is a Swift 6 iOS 18/macOS 15 library package at `ios/Shared`, with
the correct relative dependency `../../mac`. It provides strict HTTPS `.ts.net`
pairing and authenticated health-before-save with a late-response clear/re-pair
fence; Keychain bearer and separate AES-256-GCM history/IPC keys; ephemeral HTTP
sessions refusing all redirects and retaining system TLS validation; preferences
and destination-bound correction consent; allowlisted content-free diagnostics;
protected backup-excluded encrypted history and IPC; and payload-free Darwin
wake notifications using public notify.h and token cancellation.

History starts off, caps at 200 finals/4 MiB, supports 24h/7d/30d retention,
search through returned in-memory entries, raw/copy through explicit callers,
delete/clear, and atomic Use raw updates keyed by existing entry ID. Disable
persists its fence before deleting data/key. All readers/writers reread disk
settings under the same stable cross-process lock; neither racing records nor
raw updates recreate disabled history. No transcript/audio enters UserDefaults.

The mailbox is one 256 KiB bounded atomic AES-GCM document. Role checks separate
app state/result publication and keyboard commands/consumption. It enforces UUID
receipts, session generations, fresh utterances, expiry, bounded heartbeat leases,
strict result sequences and terminal final/raw ordering. It coalesces partials,
consumes text atomically and removes it on expiry reconciliation/session end.
Reconciliation only writes when pruning changes state; even a rejected subsequent
operation persists expiry cleanup. Wake callbacks retain Swift closures through
OS-managed token lifetime, with no unsafe observer pointer or plaintext payload.

Storage is synchronous: callers must use coordinator/UI worker paths, never the
real-time audio tap/converter callback. App owns audio/network/session lifetime;
keyboard reads shared state and requests commands only. Expiry deletion is
opportunistic on next access; there is no cleanup daemon. Missing/corrupt keys or
tampered ciphertext fail closed. Synthetic tests use injected roots, keys,
clocks and health/stream transports, never production credentials.

## Actual local validation

Commands were launched with `koi run`, ending the turn while each ran.

1. Initial full attempt failed compiling DarwinSignal because Swift's Darwin
   umbrella does not expose notify.h. Fixed using a SwiftPM C target importing
   the public SDK header. Second attempt failed on three Swift Testing macros
   missing an inner `try`; fixed. These were compile failures, not runtime passes.
2. Full successful run:
   `ios/Shared/scripts/test.sh && mac/scripts/test.sh && cd mac && swift build -c release`
   exited 0. Shared: **19 tests in 5 suites**; Mac: **380 tests in 61 suites**;
   release build completed. Log:
   `/Users/rex/.koi/run-logs/f786a1d5-4ac6-4abc-adda-f2e79f0d5bb8-20261018T055224-8998.log`.
   The Mac changes tested are unchanged since this run. Existing CLT search-path
   and AppKit animation/sendability warnings remain in the release build.
3. After the shared-only reconciliation optimization and strengthened notification
   test, final `ios/Shared/scripts/test.sh` on **`5419f3b`** exited 0:
   **20 tests in 5 suites**, including 23 parameterized invalid-input cases.
   Log:
   `/Users/rex/.koi/run-logs/f786a1d5-4ac6-4abc-adda-f2e79f0d5bb8-20261018T055406-13608.log`.
4. `git diff --check` passed; final working tree was clean before adding this
   evidence-only document.

Tests cover exact pairing syntax, hostile bases, authenticated health and clear
races, authorization isolation, ephemeral configuration/redirect policy, ciphertext
and backup exclusion, retention/cap/delete/clear, history tamper/missing key,
disable racing record/raw update, role/generation/utterance/replay/sequence fences,
result consumption/final/raw ordering, TTL/lease/queue/size limits, 64 concurrent
mailbox writers, rejected-operation pruning, unchanged-read no-write behavior,
notification delivery/cancellation and correction consent/diagnostics allowlists.

## Explicit remaining acceptance limits

`xcode-select -p` returns `/Library/Developer/CommandLineTools`. Full Xcode and
an iOS SDK/runtime are absent. No iOS compile, simulator launch, entitlement or
provisioning validation, on-device Keychain/App Group/file-protection execution,
background capture survival, keyboard handoff, App Intent/Live Activity or iPad
runtime acceptance is claimed. Those remain the parent/operator's Xcode/device
gates. The CLT tests validate macOS execution of portable storage/crypto/models
and notification code; they cannot establish these iOS system behaviors.
