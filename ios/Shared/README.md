# ChirpIOSCore

Swift 6 package, iOS 18/macOS 15. Product/module `ChirpIOSCore`; local dependency
`../../mac` exposes the existing `ChirpCore`. Import both modules for
`StreamSession`, `StreamTransport`, `PCMConverter`, `StartOptions`, `ServerConfig`,
`Health`, `CorrectionProfile`, `StyleCatalog` and word timings. No wire codec is
copied. The iOS app uses `StartOptions(client: "ios", ...)`; this requires the M5
server update accepting `ios` alongside `mac` and `android`.

```swift
let configuration = SharedConfiguration(bundle: .main)
let root = try configuration.containerURL()
let secrets = KeychainSecretStore(accessGroup: configuration.keychainAccessGroup)
let pairing = try PairingStore(root: root, secrets: secrets)
let credentials = try PairingLink.parse(scannedOrPastedLink)
let session = SafeHTTPSession.make() // reuse for health, profiles and StreamSession
let health = try await pairing.verifyAndSave(credentials, session: session)
let config = try pairing.load()
let bridge = try SharedBridge(root: root, secrets: secrets, role: .app)
let history = try HistoryStore(root: root, secrets: secrets)
let preferences = try PreferenceStore(root: root)
```

Set Info keys `ChirpAppGroup=group.dev.chirp.ios` and
`ChirpKeychainAccessGroup=$(AppIdentifierPrefix)dev.chirp.ios.shared` on all targets.
Xcode must expand the latter to the provisioned access group. Missing/mismatched
entitlements fail closed; the library never falls back to plaintext or defaults.
Each store creates its own protected child directory under `root`. Keychain
accounts are scoped by service `dev.chirp.ios.shared`. Keys/tokens use
AfterFirstUnlockThisDeviceOnly, are never synchronized and are excluded from
migration/backup. Directory/file backup exclusions and iOS file protection are
applied before writes. No audio API writes disk; no store writes UserDefaults.

Pairing accepts only exact `chirp://pair?url=…&token=…`, HTTPS ASCII `.ts.net`
hosts, a bounded visible ASCII bearer, no userinfo/query/fragment, and simple
unencoded base paths (e.g. `/chirp`). Nondefault HTTPS ports are allowed. Encoded
paths, public hosts and extra/duplicate parameters are rejected. All redirects
are refused, including same-origin redirects. Authenticated health must include
engine and readiness fields before persistence. An outstanding verification is
invalidated by clear/re-pair. Do not render/log pairing links or credentials.

All local store methods and initializers throw. `PairingStore.load()` returns
`ServerConfig?`; `clear()` removes credentials. `verifyAndSave` is async and returns
`Health`; tests can inject a `health: @Sendable (ServerConfig) async throws -> Health`
closure. `MemorySecretStore` is for synthetic tests only.

`PreferenceStore.load()/save(IOSPreferences)` persists only preferences;
`IOSPreferences` defaults correction off, style `default`, 5-minute sessions,
privacy off, empty prompt edits and no external consent. `permitsCorrection(health:)`
requires a disclosed destination and matching consent for external correction;
unknown destination information fails closed. `SessionDuration` cases are
`fiveMinutes`, `fifteenMinutes`, `oneHour`, `never`, with optional `seconds`.

`HistoryStore.settings()` returns enabled/retention/generation. `setEnabled`,
`setRetention(.day/.week/.month)`, `record(text:raw:corrected:) -> HistoryEntry?`,
`entries() -> [HistoryEntry]` (newest first), `delete(id:)`,
`useRaw(id:) -> HistoryEntry?`, and `clear()` are
synchronous and locked. Entries expose id, createdAt, text, raw, corrected. Search
can filter the returned in-memory entries. Only record noncancelled finals when
session privacy allows; empty entries are ignored. History defaults off, caps at
200 entries and 4 MiB, defaults to 7 days, and prunes on reads/writes/retention
changes. It has a separate AES-256-GCM Keychain key. Disabling first writes a
fence, then deletes ciphertext and key under the same multi-process lock. Reads
of disabled history retry deletion; no cached enabled flag/key can resurrect it. `useRaw` updates only an existing
retained entry using its stored raw, marks corrected false, and returns nil after
disable/clear/expiry; it cannot recreate an entry or key.

Storage methods perform synchronous bounded file IO/locking and must run only on
coordinator/UI worker paths, never an audio tap or real-time conversion callback.

Bridge usage:

```swift
let generation = UUID() // fresh for every armed session
let utterance = UUID()  // keyboard .start chooses this, app preserves it
try bridge.publish(BridgeState(generation: generation, phase: .armed,
    leaseUntil: Date().addingTimeInterval(8), availableStyleIDs: ["default", "chat"]))
// Heartbeat every ~2s, maximum 15s lease; never resurrect an expired generation.
let commands = try bridge.takeCommands(generation: generation)
// App sets state.utteranceID BEFORE publishing text, and keeps it through finished.
try bridge.publish(BridgeState(generation: generation, phase: .listening,
    utteranceID: utterance, leaseUntil: Date().addingTimeInterval(8)))
try bridge.publish(BridgeResult(generation: generation, utteranceID: utterance,
    kind: .partial, text: "synthetic", sequence: 1,
    expiresAt: Date().addingTimeInterval(10)))
DarwinSignal(name: DarwinSignal.bridgeChanged).post()
```

The keyboard instantiates `.keyboard`, sends `BridgeCommand(generation:utteranceID:
action:expiresAt:)`, reads `state() -> BridgeState?`, and calls
`takeResults(generation:utteranceID:)`. Successful take atomically consumes all
matching text; duplicate callbacks return no text. Results preserve append order,
with strictly increasing `sequence` per utterance even when timestamps tie.
Partial snapshots coalesce. Final is terminal except one subsequent raw result.
Actions: start/stop/cancel/end/useRaw/style(String)/privacy(Bool). Start needs a
fresh utterance UUID and armed/finished state; stop/cancel/useRaw require matching
utterance. Style IDs must be present in state.availableStyleIDs. SessionPhase:
idle/armed/connecting/listening/correcting/finished/failed. ResultKind:
partial/correcting/final/raw. `BridgeState` includes expiry, debugRetention,
privacyMode, styleID, availableStyleIDs and optional allowlisted errorCode.

The mailbox encrypts commands, state, prompts/style IDs and transcripts together;
only ciphertext reaches temporary or final files. AAD binds each file purpose.
Limits: 256 KiB ciphertext, 64 queued commands/results, 64 KiB text/raw per item,
120s item TTL, 512 live replay receipts, 128 live generation/utterance tombstones.
Publication rejects stale generations, foreign utterances, duplicate IDs,
nonincreasing sequences and expired leases/results. Reads reconcile expiry from
disk. `endSession()` removes all commands/text/state, keeping only encrypted
bounded replay tombstones. Call `endSession()` on every teardown. Expiry cleanup
is opportunistic at the next access; the OS does not run an expiry daemon.

Post the payload-free Darwin wake after writes. Retain
`DarwinSignal(name: DarwinSignal.bridgeChanged).observe { ... }`'s
`DarwinObservation`; call `cancel()` or release it to unregister. Wake callbacks
run off-main and may coalesce: always reread on keyboard appearance/app foreground.
The file remains authoritative. Never carry transcript data in notifications.

Diagnostics use `DiagnosticEvent(phase:code:durationMilliseconds:count:)` and
`DiagnosticExport.data(events:)`, bounded to 200 events. Codes map through
`DiagnosticCode.server(_:)`; never include server message strings or exceptions.

Run `scripts/test.sh` from any directory; it includes the CLT Testing plugin path.
Tests use temporary injected roots, MemorySecretStore, fake clocks/transports and
synthetic strings. No production credentials or network are used. Full iOS SDK
compilation/simulator, entitlement/Keychain/App Group and device behavior require
Xcode/operator validation; a macOS test pass is not iOS runtime evidence.
