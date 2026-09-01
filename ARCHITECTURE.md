# BASE Architecture

Last synchronized with Fleet field release: `0.23.0-alpha.5.4`.

This file is an architectural reference. For exact deployed bytes, versions and hashes, `deploy.json`, `packages.json`, `fleet.json` and the source files referenced by those manifests are authoritative.

## 1. Platform

BASE runs on CC:Tweaked as ported by Polymania. Upstream CC:Tweaked behavior is a useful reference, but runtime behavior must be feature-detected and field-tested because Polymania and server configuration can differ.

Current server storage quota is approximately 8 MiB per computer. Storage is no longer the dominant design constraint; tick/CPU scheduling, event handling and network traffic remain important constraints.

## 2. Boot and trusted runtime

The normal BASE path is:

`startup.lua -> main.lua -> Dashboard/UI -> Apps/Games + services`

Trusted applications use the BASE runtime environment and `cc.require.make`. Sandboxed applications use an explicit environment and `loadfile(..., env)` with virtual storage under `/data/sandbox/<app>`. Do not use CraftOS `os.run` as a sandbox boundary because fallback to the host environment can leak capabilities.

`/data` contains user and runtime state and must not be wiped during normal updates.

## 3. Packages and updates

The package/update stack introduced in 0.21 uses immutable source commits and `git-blob-sha1` for exact content verification. A blob hash proves byte identity, not publisher authenticity.

Field Fleet deployments use `fleet.json`. The updater preserves operator/agent configuration and installs role profiles (`assault`, `relay`, `pocket`). Active Fleet jobs must not be updated in-place.

## 4. Storage and services

0.22 added the Service Supervisor, System Status, Explorer/Commander and Storage tooling. Protected system prefixes include `/data/system`, `/data/security`, `/lib`, `/apps`, `/games` and manifest/updater paths. Copying a file does not transfer package ownership.

## 5. Network stack

The long-term BASE stack remains layered:

`modem/rednet -> transport -> protocol/service -> peers/pairing -> CCIP/routing -> CCDP datagram -> CCTP stream -> apps`

Firewall/security policy is cross-cutting.

### Observed Polymania transport behavior

Current field tests show direct modem/rednet connectivity at distances greater than 3000 blocks and across dimensions, including Overworld/Nether tests. A separate modem-only computer also discovered distant modem computers. The server was known to have intentionally increased ordinary modem range from 64 to about 96 blocks, so the global/interdimensional behavior is treated as **observed but not guaranteed**. Its origin may be a Polymania behavior, server configuration or bug.

Therefore BASE must support both direct and mesh transport:

- `DIRECT`: direct delivery through the current modem fabric.
- `MESH`: dedicated RELAY nodes may forward BASE packets.
- `AUTO`: prefer direct delivery and retain mesh as fallback.

Never remove the mesh implementation solely because current direct transport appears global.

ASSAULT/ENGINEER workers are endpoints, not general-purpose relays. Dedicated `RELAY` nodes forward traffic. This avoids the flooding observed when every worker relayed packets.

### Future router role

Routers are intended to become security gateways rather than range extenders. Future GlobalNet design should support router-mediated authentication, ACL/firewall policy, service routing, rate limiting, traffic budgets, DDoS protection, audit/IDS and redundant routers. Endpoints must enforce router/session policy themselves because all nodes may still physically share the same modem fabric.

## 6. Fleet runtime

Fleet uses a signed packet format (currently HMAC-SHA1 with a shared fleet key; this is interim security). Packets include TTL/deduplication and command idempotency fields.

### Roles

- `ASSAULT`: current general worker/raid endpoint.
- `RELAY`: networking-only relay role.
- Planned `ENGINEER`: industrial digging/building on own/allied claims.
- Planned `RAID`: movement + attack in hostile claims, without relying on dig/place.
- `DEFENSE`: own-claim defense stack, currently separate from Fleet.

### Claim behavior confirmed in field tests

- Turtle movement into enemy/private claims works.
- `turtle.attack()` against hostile players works in enemy claims.
- `turtle.dig()` is blocked by claim protection in enemy/private claims.
- `turtle.place()` in enemy claims remains unconfirmed.

Industrial mining jobs must therefore target own/allied territory. Raid design must not depend on turtle digging through enemy claims.

## 7. Fleet job execution

The early 0.23 job executor used a chain of one-shot timers and could strand turtles in `JOB:OUT` while the network/status loop stayed alive. 0.23.0-alpha.4.2 replaced that design with separated worker/network/status loops and is field-verified with 4, 12 and 18 simultaneous turtles across multiple step delays.

Completion correctness is based on a persistent completion ledger (`lastJob`) keyed by job ID. A bare terminal state such as `JOB_DONE` is not sufficient to prove that the current scheduler run has completed.

Scheduler state and completion state survive Pocket/app restarts. Turtle job state is checkpointed for recovery. A reboot cannot be made mathematically atomic with physical movement without a stronger write-ahead/reconciliation protocol, so crash recovery must remain conservative.

## 8. Fleet scheduling and performance

The scheduler supports:

- `ALL` concurrency;
- fixed concurrency;
- `AUTO` concurrency;
- `DIRECT`, `MESH`, `AUTO` transport policy;
- persistent run state and history;
- delay and concurrency benchmarking.

The load governor is deliberately slow. Current constants use roughly 30-second observation epochs, at least 60 seconds between control changes, two confirming epochs and concurrency steps of at most 2 workers. Step delay is fixed for the duration of an individual job; it is not continuously retuned.

Current field profile from an 18-unit, 50-block benchmark:

- recommended delay: `0.15` (current low-confidence sample set);
- fixed 4: ~303.7 s / 2.91 blk/s;
- fixed 6: ~227.5 s / 3.96 blk/s;
- fixed 10: ~231.8 s / 3.89 blk/s;
- fixed 14: ~211.8 s / 4.25 blk/s;
- fixed 18: ~195.6 s / 4.60 blk/s;
- AUTO: ~184.6 s / 4.88 blk/s, observed adaptive target around 9.

These measurements are server-state observations, not universal constants. Performance profiles accumulate multiple sessions and should not be treated as permanent server guarantees.

## 9. Pocket / local UI

0.23.0-alpha.5.4 introduces a unified pointer host for Fleet applications. On Polymania, keyboard input is inconvenient on Pocket and ordinary computers, so primary interaction is `mouse_click`/`monitor_touch` where available. Pointer controls occupy a dedicated panel below the legacy application window. Keyboard arrows/hotkeys remain fallback inputs.

Numeric forms use pointer-adjustable values instead of requiring CraftOS `read()`/the on-screen keyboard for normal operation. Existing Fleet cores remain separate from the pointer wrappers so tested job/network logic is not rewritten solely for UI changes.

## 10. Defense

Defense Foundation exists but has known technical debt:

- Defense agent/controller still contain historical melee-unavailable assumptions even though server turtle attack was later fixed.
- Controller stale-return/fail-safe latch race remains unresolved.

Do not silently reuse Fleet raid behavior as Defense behavior until these are explicitly repaired and tested.

## 11. Planned Industrial Fleet

The next major Fleet phase is an industrial job engine. Target primitives include Tunnel, Excavate Box, Quarry, later Strip Mine, unload/refuel and persistent resume. Job types should share a planner/executor/checkpoint/fuel/inventory foundation rather than duplicating movement logic.

## 12. Future RISC-V VM

The server plans a RISC-V VM integration for CC:Tweaked/Polymania. Exact ISA, memory and guest interface are not yet available. Do not rewrite BASE around assumptions about the VM.

Preferred future architecture:

`CC:Tweaked/Polymania -> Lua Host/HAL -> stable BASE ABI -> Lua processes and RISC-V VM guests`

The BASE ABI should eventually abstract filesystem, event/timer, terminal, modem/network, turtle and peripheral operations. Packages should evolve toward architecture/ABI metadata and capsules should become backend-neutral process containers.
