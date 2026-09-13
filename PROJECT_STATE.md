# BASE Project State

Last synchronized release target: `0.23.0-alpha.6.1.1`.

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

The `0.23.0-alpha.4.2` physical job executor remains the stable turtle core. It is field-verified with 4, 12 and 18 simultaneous turtles and multiple delays. Completion is correlated by `jobId` through the persistent `lastJob` ledger.

`0.23.0-alpha.5.4.5` is the field-verified pointer/UI baseline. Numeric forms use Left/Right to adjust values, Up=`Default`, Down=`OK`, Enter=activate. Scheduler and Jobs start/confirmation behavior is verified on Polymania.

`0.23.0-alpha.6.0` introduced `/lib/fleet/industrial.lua`: normalized Tunnel/Excavate Box/Quarry specifications, serpentine planning, conservative fuel estimates, work-slot inventory pressure and a versioned checkpoint model. Deployment and ordinary Tunnel regression testing passed.

`0.23.0-alpha.6.1` migrated Tunnel preflight, fuel projection and Industrial checkpoint bookkeeping onto that shared contract while preserving the alpha4.2 physical `detect/dig -> forward -> back` loop. Field testing confirmed Tunnel completion and a terminal `DONE` checkpoint.

`0.23.0-alpha.6.1.1` adds `/lib/fleet/security.lua` as endpoint Fleet Guard. Pocket Fleet Control already has a pointer-accessible `Update` action on its second page; this release hardens the receiving turtle/relay path rather than adding a second updater. The guard performs a cheap command-envelope precheck, rate-limits new authenticated command requests per operator boot, applies a shorter freshness window to remote update, persists accepted-update identity across reboot, rejects replay after reboot, and enforces a 30-second update cooldown. Rejected authenticated requests are returned as `fleet_guard:*` results and recorded in bounded `/data/fleet_security_log.json`. Field verification of alpha6.1.1 is pending.

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
- Remote updates may be initiated from Fleet Control with `Update`; alpha6.1.1 applies endpoint freshness/replay/cooldown policy before the unchanged core can schedule the reboot/update.
- `/data/fleet_security_log.json` is the first diagnostic for a rejected authenticated Fleet command.
- The CCIP firewall and Fleet Guard protect different paths. Fleet uses its own signed rednet command protocol and therefore needs endpoint policy even when the BASE firewall is enabled.
- The shared Fleet HMAC key remains an interim trust model. Fleet Guard limits repeated/replayed commands but does not create a second trust domain if that shared key is compromised.
- Treat Industrial planner/checkpoint values as the common contract for new industrial job types; do not duplicate geometry/fuel/inventory rules in UI or worker code.

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
15. Industrial checkpoint recovery cannot guarantee atomic correspondence with physical movement after power loss; stronger reconciliation is still required.

## Immediate roadmap

### 0.23.0-alpha.6 — Industrial Fleet

- `alpha.6.0`: shared planner/spec/checkpoint/fuel/inventory foundation — field regression passed.
- `alpha.6.1`: Tunnel preflight/fuel/checkpoint integration with unchanged physical loop — field-tested successfully.
- `alpha.6.1.1`: endpoint Fleet Guard and hardened Pocket-triggered remote update — field verification pending.
- next: `alpha.6.2` Excavate Box execution and single-unit recovery/inventory/fuel field tests.
- then: Quarry on the same serpentine executor, followed by multi-unit scheduling and Industrial Pocket UI.
- later within the phase: unload/refuel workflows, stronger restart reconciliation and ENGINEER role separation where appropriate.

### 0.24 — BASE Pocket OS 2

Unified Fleet/Jobs/Nodes/Network/Diagnostics/Updates/Defense/Messages/Settings experience built on the shared pointer/navigation UI.

### Later

GlobalNet/router security, per-device/session keys, stronger maintenance authorization, traffic protection, Defense/Raid cleanup and eventually RISC-V ABI/VM enablement.
