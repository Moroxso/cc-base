# BASE Project State

Last synchronized release target: `0.23.0-alpha.6.2`.

Canonical priority when information conflicts:

1. live `main` source and release manifests (`deploy.json`, `packages.json`, `fleet.json`);
2. this project-state documentation;
3. old branches, chat summaries and historical notes.

## Completed milestones

### 0.21 — Package Manager / Updater v2

Package dependency/ownership handling, updater journal/fallback behavior, mount-aware storage and immutable blob verification are implemented. Polymania required preserving the program environment when loading updater code.

### 0.22 — Storage / Service Supervisor

Service Supervisor, System Status, Explorer/Commander and Storage management are implemented and field-tested.

### 0.23 — Defense / Fleet

Defense Foundation exists. Fleet includes signed DIRECT/MESH/AUTO transport, Pocket control, ASSAULT/RELAY profiles, field updater/watchdog, local NAV/tool handling, Jobs, Scheduler/load governor, persistent completion ledger, performance profiling and pointer-first local UI.

## Current Fleet field status

The `0.23.0-alpha.4.2` physical Tunnel executor remains the stable turtle core. It is field-verified with 4, 12 and 18 simultaneous turtles and multiple delays. Completion is correlated by `jobId` through the persistent `lastJob` ledger.

`0.23.0-alpha.5.4.5` is the field-verified pointer/UI baseline. Numeric forms use Left/Right to adjust values, Up=`Default`, Down=`OK`, Enter=activate. Scheduler and Jobs start/confirmation behavior is verified on Polymania.

`0.23.0-alpha.6.0` introduced the Industrial planning/checkpoint contract: normalized Tunnel/Excavate Box/Quarry specifications, serpentine planning, fuel estimates, work-slot inventory pressure and versioned checkpoints. Deployment and ordinary Tunnel regression testing passed.

`0.23.0-alpha.6.1` migrated Tunnel preflight, fuel projection and Industrial checkpoint bookkeeping onto that shared contract while preserving the alpha4.2 physical `detect/dig -> forward -> back` loop. Field testing confirmed Tunnel completion and a terminal `DONE` checkpoint.

`0.23.0-alpha.6.1.1` added endpoint Fleet Guard. Remote update from Pocket Fleet Control, the reboot-spanning update replay state and the 30-second update cooldown were field-tested successfully on Polymania. Fleet Guard remains a resilience layer over the shared Fleet HMAC key, not a separate authorization domain.

`0.23.0-alpha.6.2` is the current field-test target. It adds the first physical Excavate Box executor as a **single-unit** job without replacing the field-verified Tunnel core. `/assault_agent.lua` is now a thin Box ownership layer; it delegates normal Fleet commands to the alpha6.1.1 guarded wrapper at `/assault_agent_guarded.lua`, which in turn loads the unchanged alpha4.2 `/assault_agent_core.lua`.

The alpha6.2 Box executor uses the shared deterministic serpentine cell order, enters the first work cell from the origin, traverses adjacent cells, and returns by exactly reversing the excavated prefix. The runtime therefore reserves worst-case movement fuel as `2 * volume + 64`; the deployed Industrial compatibility layer reports that same exact-retrace return budget. Slots 1–4 remain fuel slots and slots 5–16 remain work inventory.

Box writes `/data/fleet_industrial_job.json` after each confirmed movement. Before each physical move it persists a movement intent. If the computer restarts while an intent is still unresolved, alpha6.2 deliberately enters `JOB:RECOVERY_REQUIRED` instead of guessing whether the physical movement happened. A clean checkpoint without unresolved intent may resume. Inventory pressure or insufficient safe return fuel causes a return toward origin; automatic unload/refuel station workflows are not implemented yet.

For staged field testing, Box has a separate pointer-compatible Pocket program at `/fleet_box.lua`. It accepts one explicit turtle ID plus Width/Length/Height/Delay. Group scheduling, integration into the normal Fleet Jobs menu and multi-unit Box partitioning are intentionally deferred until single-unit geometry, return, cancel and recovery behavior are field-verified.

## Polymania/server observations

- Per-computer storage quota is approximately 8 MiB.
- Direct wireless communication has been observed beyond 3000 blocks and across dimensions, but this is observed behavior rather than a permanent transport contract.
- Server intentionally increased expected ordinary modem radius from vanilla 64 to about 96 blocks; this does not explain the observed global behavior by itself.
- Turtle movement and attack work in hostile claims; `turtle.dig()` is blocked by hostile/private claim protection.
- `turtle.place()` behavior in hostile claims remains unconfirmed.
- No additional entity sensor peripheral is currently available.
- Optional `keys.*` constants must be feature-detected on Polymania.

## Current production recommendations

- Use `AUTO` Fleet transport unless deliberately testing DIRECT/MESH behavior.
- Keep dedicated RELAY nodes available; normal workers should not relay.
- Use Scheduler AUTO concurrency for large Tunnel work unless benchmarking a fixed setting.
- Do not update an active turtle job.
- Preserve `/data`, including Fleet job/checkpoint/security state, during updates.
- Remote updates may be initiated from Fleet Control with `Update`; Fleet Guard applies endpoint freshness/replay/cooldown policy before the unchanged core can schedule reboot/update.
- `/data/fleet_security_log.json` is the first diagnostic for a rejected authenticated Fleet command.
- The CCIP firewall and Fleet Guard protect different paths. Fleet uses its own signed rednet command protocol and therefore needs endpoint policy even when the BASE firewall is enabled.
- The shared Fleet HMAC key remains an interim trust model. Fleet Guard limits repeated/replayed commands but does not create a second trust domain if that shared key is compromised.
- Treat the shared Industrial API as the source of truth for geometry/fuel/checkpoint rules.
- Until alpha6.2 is field-verified, run Excavate Box on one test turtle only and use `/fleet_box.lua`; do not treat it as a fleet-scale production primitive yet.

## Open technical debt

1. Defense melee assumptions are stale after the server combat fix.
2. Defense controller stale-return/fail-safe race remains open.
3. Fleet still uses one shared HMAC-SHA1 fleet key; per-device/session and separate maintenance keys remain future work.
4. HMAC-SHA1 and current entropy/key provisioning are interim.
5. Common canonical serialization needs review for mixed numeric-key map edge cases.
6. RTB has no obstacle pathfinding.
7. NAV can drift after external movement or unreconciled physical changes.
8. `turtle.place()` hostile-claim behavior remains unverified.
9. Watchdog maintenance mode is limited.
10. Automatic power-on after placing a turtle/computer block is not guaranteed.
11. Command freshness depends on runtime epoch behavior.
12. Global/interdimensional modem delivery implementation remains unknown.
13. GlobalNet router/firewall/session/rate-control work is still planned.
14. RISC-V VM details are unknown and must not be guessed.
15. Box recovery after an unresolved movement intent deliberately requires operator reconciliation; automatic physical reconciliation is not implemented.
16. Industrial unload/refuel stations and multi-unit Box/Quarry partitioning are not implemented.

## Immediate roadmap

### 0.23.0-alpha.6 — Industrial Fleet

- `alpha.6.0`: shared planner/spec/checkpoint/fuel/inventory foundation — field regression passed.
- `alpha.6.1`: Tunnel preflight/fuel/checkpoint integration with unchanged physical loop — field-tested successfully.
- `alpha.6.1.1`: endpoint Fleet Guard and hardened Pocket-triggered remote update — field-tested successfully.
- `alpha.6.2`: single-unit Excavate Box executor, exact reverse return, write-intent checkpointing and standalone Pocket test UI — implementation complete, field verification pending.
- next after alpha6.2 verification: recovery/inventory/fuel edge tests, then Quarry on the same executor model.
- then: multi-unit industrial scheduling and integration into the normal Jobs/Pocket UI.
- later within the phase: unload/refuel workflows, stronger restart reconciliation and ENGINEER role separation where appropriate.

### 0.24 — BASE Pocket OS 2

Unified Fleet/Jobs/Nodes/Network/Diagnostics/Updates/Defense/Messages/Settings experience built on the shared pointer/navigation UI.

### Later

GlobalNet/router security, per-device/session keys, stronger maintenance authorization, traffic protection, Defense/Raid cleanup and eventually RISC-V ABI/VM enablement.
