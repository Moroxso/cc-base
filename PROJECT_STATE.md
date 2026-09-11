# BASE Project State

Last synchronized release target: `0.23.0-alpha.5.4.3.1`.

Canonical priority when information conflicts:

1. live `main` source and release manifests (`deploy.json`, `packages.json`, `fleet.json`);
2. this project-state documentation;
3. old branches, chat summaries and historical notes.

## Completed milestones

### 0.21 — Package Manager / Updater v2

Package dependency/ownership handling, updater journal/fallback behavior, mount-aware storage and immutable blob verification are implemented. Polymania required preserving the program environment when loading updater code.

### 0.22 — Storage / Service Supervisor

Service Supervisor, System Status, Explorer/Commander and Storage management are implemented and field-tested. Confirmation handling accepts physical key events after a Polymania input compatibility hotfix.

### 0.23 — Defense / Fleet

Defense Foundation exists. Fleet now includes signed mesh/common protocol, Pocket control, assault/relay profiles, field updater/watchdog, local NAV/tool handling, Fleet Jobs, BASE Pocket OS, parallel job execution, persistent completion ledger, Scheduler/load governor, performance benchmarking/profile and pointer-first local UI.

## Current Fleet field status

`0.23.0-alpha.4.2` job execution model is the stable turtle core. Tests with 4, 12 and 18 turtles completed tunnel round trips successfully across multiple step delays. Server scheduling creates noticeable per-turtle timing variance as fleet size grows, but workers continue progressing and complete.

`0.23.0-alpha.5.1` fixed false Scheduler completion by persisting and correlating `lastJob.id`.

`0.23.0-alpha.5.2/.5.3` added delay/concurrency benchmarking and an accumulated performance profile. Latest observed 18-unit profile favors delay `0.15` and AUTO concurrency, but values remain recommendations rather than permanent constants.

`0.23.0-alpha.5.4` introduced pointer wrappers around unchanged Fleet cores.

`0.23.0-alpha.5.4.1` made failed launches observable.

`0.23.0-alpha.5.4.2` restored a complete trusted CC program environment for wrapped cores using `cc.require.make(env, dir)`, absolute host loading and Polymania file-handle compatibility. Field testing confirmed all Fleet menus launch correctly in this version.

`0.23.0-alpha.5.4.3` attempted keyboard-focus navigation by proxying `os.pullEvent` and capturing navigation events before the legacy cores. Field testing immediately regressed all Fleet wrappers to `shell.run returned false`. Because the failure affects all four wrappers while the same cores work under alpha5.4.2, the regression is isolated to the new pointer-host/event interception layer. The exact runtime error must be read from the persistent pointer diagnostic before another navigation implementation is promoted.

`0.23.0-alpha.5.4.3.1` is an immediate production rollback: the Fleet manifest points back to the exact field-verified alpha5.4.2 pointer host/core and payload while preserving `/data` diagnostics. Keyboard focus is therefore temporarily removed; pointer/touch remains the production UI until the regression is diagnosed exactly.

## Polymania/server observations

- Per-computer storage quota is approximately 8 MiB.
- Direct wireless communication has been observed beyond 3000 blocks and across dimensions.
- This global/interdimensional delivery is observed behavior, not a guaranteed modem contract; mesh remains mandatory fallback infrastructure.
- Server intentionally increased expected modem radius from vanilla 64 to about 96 blocks, which does not explain the observed global behavior by itself.
- Turtle attack works, including against hostile players inside enemy claims.
- Turtle dig works on own/allied territory but is blocked by enemy/private claim protection.
- Turtle place behavior in hostile claims remains unconfirmed.
- No additional entity sensor peripheral is currently available.

## Current production recommendations

- Use `AUTO` Fleet transport unless deliberately testing DIRECT/MESH behavior.
- Keep dedicated RELAY nodes available; ASSAULT workers should not relay.
- Use Scheduler AUTO concurrency for large tunnel jobs unless a test specifically requires fixed concurrency.
- Treat saved performance values as recommendations, not guarantees.
- Do not update an active turtle job.
- Preserve `/data` during updates.
- For pointer UI failures, inspect `/data/pointer_ui_error.log` and `/data/pocket_launch_error.log` before changing Fleet cores.
- Custom trusted environments using `require` must construct `require/package` with `cc.require.make`; inheriting only `_G` is insufficient.
- Do not reintroduce global event interception for keyboard navigation until the alpha5.4.3 failure is diagnosed from a concrete field log.

## Open technical debt

1. Defense melee capability assumptions are stale after the server combat fix.
2. Defense controller stale-return/fail-safe race remains open.
3. Fleet currently uses one shared HMAC-SHA1 fleet key; capture of one trusted node can compromise the fleet.
4. HMAC-SHA1 and current entropy/key provisioning are interim.
5. Common canonical serialization needs review for mixed numeric-key map edge cases.
6. RTB has no obstacle pathfinding.
7. NAV can drift after external movement or unreconciled physical changes.
8. `turtle.place()` hostile-claim behavior remains unverified.
9. Watchdog maintenance mode is limited.
10. Automatic power-on after placing a turtle/computer block is not guaranteed.
11. Command freshness depends on runtime epoch behavior.
12. Global/interdimensional modem delivery implementation remains unknown.
13. Router/firewall/DDoS GlobalNet design is planned, not implemented.
14. RISC-V VM details are unknown and must not be guessed.
15. Keyboard-focus navigation for pointer panels is currently rolled back pending exact diagnosis.

## Immediate roadmap

### 0.23.0-alpha.5.4.3.1 — Pointer rollback

- restore exact alpha5.4.2 pointer host/core;
- keep pointer/touch controls working;
- preserve diagnostic files under `/data`;
- collect the concrete alpha5.4.3 pointer error before redesigning keyboard focus;
- no Fleet worker/job/network semantics changes.

### Follow-up pointer navigation

Implement arrow navigation with the smallest possible change after the field error is known. Avoid intercepting all core event pulls unless proven necessary. Fleet Control must still prevent a navigation arrow from simultaneously issuing movement.

### 0.23.0-alpha.6 — Industrial Fleet

Initial scope: common industrial job engine, Tunnel migration where safe, Excavate Box, Quarry, persistent checkpoints, inventory-full handling, fuel projection/refuel handling and Industrial Pocket UI.

### 0.24 — BASE Pocket OS 2

Broader unified Pocket platform: Fleet/Jobs/Nodes/Network/Diagnostics/Updates/Defense/Messages/Settings, built on the shared pointer/navigation UI.

### Later

GlobalNet/router security, per-device/session keys, DDoS protection, Defense/Raid profile cleanup and eventually RISC-V ABI/VM enablement.
