# BASE Development Rules

Last synchronized with `0.23.0-alpha.5.4`.

These rules exist to keep changes auditable and to reduce regressions and context drift.

## 1. Canonical sources

Always inspect current `main` before modifying a subsystem. Release manifests and live source are canonical. Documentation must be updated when architectural assumptions, field constraints or major roadmap state changes.

Do not rely on a long chat history as the only project memory. Keep `ARCHITECTURE.md`, `PROJECT_STATE.md`, `DECISION_LOG.md` and this file current in `main`.

## 2. Branch/release workflow

Normal workflow:

1. branch from current `main`;
2. make the smallest coherent change;
3. run local Lua syntax validation (`texluac -p` where available);
4. audit the branch diff against `main`;
5. freeze an immutable payload commit;
6. generate/update release manifest hashes and sizes against that payload;
7. verify branch is not behind `main`;
8. fast-forward `main` without force;
9. field-test on Polymania before promoting experimental behavior to a broader BASE manifest.

Do not modify unrelated games/network/security/Defense files while doing Fleet/UI work unless the change is explicitly required and audited.

## 3. Polymania compatibility

Treat upstream CC:Tweaked documentation as reference, not proof of runtime behavior. Feature-detect and field-test port-specific behavior.

Known compatibility examples:

- preserve program environment when loading updater code;
- avoid sandbox `os.run` environment leakage;
- keyboard/event handling may differ enough that pointer input is preferred for Pocket and local GUI operation;
- direct modem delivery currently behaves far beyond the nominal configured range, but this must not be assumed permanent.

## 4. UI rules

For new interactive Fleet/Pocket/local-computer tools:

- Primary: `mouse_click` and `monitor_touch` where available.
- Secondary/fallback: arrows, Enter, Escape and existing hotkeys.
- Do not require CraftOS `read()`/the on-screen keyboard for ordinary numeric choices such as distance, delay, repeats or concurrency.
- Text entry may retain keyboard fallback when the value is inherently textual (names/IDs/shell).
- Keep actions visible and clickable; do not depend on memorized single-letter commands.
- Long-running work must continue to process network/status events while UI is open.
- UI wrappers must not silently change job/network semantics.

## 5. Fleet execution rules

- Stable physical worker code is high-risk: avoid rewriting it for UI-only releases.
- Commands must remain idempotent across retries.
- Completion must correlate to the active `jobId`; never infer current completion from a bare stale terminal state.
- Persist enough job/result state to recover Pocket/app restarts.
- Do not claim perfect crash atomicity for physical movement without a real write-ahead/reconciliation design.
- Updates during active jobs are blocked/deferred.
- Dedicated RELAY nodes forward mesh packets; normal workers do not.

## 6. Scheduler/load rules

Do not build a high-frequency controller that changes fleet parameters every second. Server scheduling is noisy and nonlinear.

Current design policy:

- collect telemetry frequently;
- make control decisions over long epochs;
- require hysteresis/confirming samples;
- use cooldown between changes;
- change concurrency in small steps;
- keep per-job step delay fixed while that job runs.

Benchmarks should keep workload comparable and, when practical, alternate/randomize setting order to reduce bias from changing server load.

## 7. Network/security rules

Current Fleet HMAC is an interim protection layer. Do not treat computer ID, channel number or physical range as authentication.

Long-term GlobalNet must separate:

- physical modem fabric;
- transport selection (DIRECT/MESH/AUTO);
- logical routing/addressing;
- authentication/session identity;
- firewall/ACL policy;
- service routing;
- rate limiting/congestion/DDoS controls.

Because the physical modem domain may be global, endpoints must reject unauthorized traffic themselves; a router cannot physically prevent a hostile sender from transmitting toward an endpoint.

## 8. Storage/data rules

`/data` is persistent user/runtime state. Do not wipe it during upgrades.

The current quota is about 8 MiB, so structured logs, performance histories, rollback state and future VM/package artifacts are acceptable, but data must still be bounded/rotated.

Use temporary-file + move patterns for important JSON state where practical.

## 9. Manifest integrity

`git-blob-sha1` is used for exact content identity. It is not a signing system and does not establish publisher trust.

For every Fleet field release, verify all manifest sizes/hashes against the immutable `sourceCommit` and do not change runtime payload files after that commit without producing a new source commit.

## 10. Documentation hygiene

Every major release should update the docs if it changes one of these:

- architecture;
- verified server/Polymania behavior;
- security assumptions;
- release workflow;
- known technical debt;
- roadmap priorities;
- field-tested performance/capability constraints.

Prefer concise current facts over exhaustive historical narration. Historical rationale belongs in `DECISION_LOG.md`.
