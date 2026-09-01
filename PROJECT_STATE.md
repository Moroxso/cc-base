# BASE Project State

Last synchronized release target: `0.23.0-alpha.5.4`.

Canonical priority when information conflicts:

1. live `main` source and release manifests (`deploy.json`, `packages.json`, `fleet.json`);
2. this project-state documentation;
3. old branches, chat summaries and historical notes.

## Completed milestones

### 0.21 — Package Manager / Updater v2

Package dependency/ownership handling, updater journal/fallback behavior, mount-aware storage and immutable blob verification are implemented. Polymania required preserving the program environment when loading updater code (`loadfile(..., PROGRAM_ENV)`).

### 0.22 — Storage / Service Supervisor

Service Supervisor, System Status, Explorer/Commander and Storage management are implemented and field-tested. Confirmation handling accepts physical `keys.y/n` after a Polymania input compatibility hotfix.

### 0.23 — Defense / Fleet

Defense Foundation exists. Fleet was expanded substantially:

- signed mesh/common protocol;
- Pocket control;
- assault/relay profiles;
- field updater/watchdog;
- local NAV/tool handling;
- Fleet Jobs;
- BASE Pocket OS;
- parallel job worker runtime;
- persistent completion ledger;
- Scheduler and load governor;
- performance benchmarking/profile;
- pointer-first Fleet UI host in alpha5.4.

## Current Fleet field status

`0.23.0-alpha.4.2` job execution model is the stable turtle core. Tests with 4, 12 and 18 turtles completed tunnel round trips successfully at delays including 0.05, 0.15, 0.25, 0.5 and 1.0. Server scheduling creates noticeable per-turtle timing variance as the fleet grows, but workers continue making progress and complete.

`0.23.0-alpha.5.1` fixed false scheduler completion by persisting and correlating `lastJob.id`.

`0.23.0-alpha.5.2/.5.3` added delay/concurrency benchmarking and an accumulated performance profile. Latest observed 18-unit profile favors delay `0.15` and AUTO concurrency; the sample confidence is still low and must not be promoted to a permanent constant.

`0.23.0-alpha.5.4` changes UI only. Stable Fleet cores are installed separately and launched through pointer wrappers. No turtle movement/job algorithm is intentionally changed by this release.

## Polymania/server observations

- Per-computer storage quota is approximately 8 MiB.
- Direct wireless communication has been observed beyond 3000 blocks and across dimensions.
- This is not assumed to be a guaranteed modem contract; mesh support remains mandatory fallback infrastructure.
- Server intentionally increased the expected modem radius from vanilla 64 to about 96 blocks, which does not by itself explain the observed global behavior.
- Turtle attack currently works, including against hostile players inside enemy claims.
- Turtle dig works on own/allied territory but is blocked by enemy/private claim protection.
- Turtle place behavior in hostile claims remains unconfirmed.
- No additional entity sensor peripheral is currently available; standard turtle block detection/inspection remains the reliable local sensor API.

## Current production recommendations

- Use `AUTO` Fleet transport unless deliberately testing DIRECT/MESH behavior.
- Keep dedicated RELAY nodes available; do not make ASSAULT workers relays.
- Use Scheduler AUTO concurrency for large tunnel jobs unless a test specifically requires fixed concurrency.
- Treat saved performance values as recommendations, not guarantees.
- Do not update an active turtle job.
- Preserve `/data` during updates.

## Open technical debt

1. Defense melee capability assumptions are stale after the server combat fix.
2. Defense controller stale-return/fail-safe race remains open.
3. Fleet currently uses a shared HMAC-SHA1 fleet key; capture of one trusted node can compromise the fleet.
4. HMAC-SHA1 is interim; entropy/key provisioning is not a complete modern key-management system.
5. Common canonical serialization still needs review for mixed numeric-key map edge cases.
6. RTB is direct/local-navigation based; no obstacle pathfinding.
7. NAV can drift after external movement or unreconciled physical changes.
8. `turtle.place()` hostile-claim behavior remains unverified.
9. Watchdog maintenance mode is still limited.
10. Automatic power-on after placing a turtle/computer block is not guaranteed.
11. Command freshness depends on runtime epoch behavior.
12. Global/interdimensional modem delivery is observed but its exact server implementation is unknown.
13. Router/firewall/DDoS GlobalNet design is planned, not implemented.
14. RISC-V VM details are unknown and must not be guessed.

## Immediate roadmap

### 0.23.0-alpha.5.4 — Pointer UI / docs refresh

- unified pointer host;
- mouse/touch control panel for Fleet Control, Jobs, Scheduler and Performance;
- numeric pointer input without normal dependence on on-screen keyboard;
- clickable BASE Pocket main menu;
- bring project-context Markdown files into `main` and keep them in release workflow.

### 0.23.0-alpha.6 — Industrial Fleet

Initial scope:

- common industrial job engine;
- Tunnel migration to common primitives where safe;
- Excavate Box;
- Quarry;
- persistent checkpoints;
- inventory-full handling;
- fuel projection/refuel handling;
- Industrial Pocket UI using the pointer framework.

Later industrial work: Strip Mine, unload/base logistics and building jobs.

### 0.24 — BASE Pocket OS 2

Broader unified Pocket platform: Fleet/Jobs/Nodes/Network/Diagnostics/Updates/Defense/Messages/Settings, built on the shared pointer/navigation UI rather than independent hotkey screens.

### Later

GlobalNet/router security, per-device/session keys, DDoS protection, Defense/Raid profile cleanup and eventually RISC-V ABI/VM enablement.
