# cc-base — Architecture

This document describes stable subsystem boundaries. It is intentionally higher-level than source code. For implementation details, inspect the current files in GitHub.

## Runtime model

`startup.lua` is the boot entrypoint. It launches `/main.lua` and provides a visible boot-error fallback instead of silently failing.

`main.lua` is the system shell/dashboard. It creates long-lived services and runs them concurrently with the interactive UI through `parallel.waitForAny`.

Current long-lived service instances are:

- Automation;
- NetworkService;
- IPService;
- DatagramService;
- StreamService;
- SecurityService.

Applications and games are launched through `lib.runtime` so they execute in their own program environments instead of sharing the dashboard’s local state directly.

## Repository layout

```text
.
├── deploy.json
├── src/
│   ├── startup.lua
│   ├── main.lua
│   ├── update.lua
│   ├── rescue_update.lua
│   ├── apps/
│   ├── games/
│   └── lib/
│       ├── gui/
│       ├── input/
│       ├── net/
│       └── security/
```

`deploy.json` is the release manifest. A file under `src/` is not automatically installed on CC computers unless the manifest maps it to a target path. `rescue_update.lua` is currently intentionally outside the normal deployment manifest.

## System shell and UI

### `src/main.lua`

Responsibilities:

- main dashboard;
- system status;
- application/game launching;
- reboot/shutdown actions;
- concurrent background service lifetime.

The dashboard is not the implementation home for each feature. Subsystems belong in libraries or separate applications.

### `src/lib/ui.lua`

Shared low-level terminal drawing helpers.

### `src/lib/gui/`

Reusable widgets currently include:

- `button.lua`;
- `screen.lua`;
- `toggle.lua`;
- `slider.lua`;
- `tabbar.lua`;
- `list.lua`.

The GUI is event-driven and must support CC terminal constraints, keyboard navigation, mouse input where available, and redraw after terminal resize where the calling program supports it.

### `src/lib/input/`

Contains input behavior such as key-repeat support.

## Program runtime and sandbox

`src/lib/runtime.lua` provides two execution profiles:

- trusted programs;
- capability-sandboxed programs.

Trusted execution creates a program environment with its own `require`/`package` setup and program-relative module lookup.

Sandboxed execution delegates environment construction to `lib.security.sandbox` and loads the program with an explicit environment using `loadfile`.

Important invariant: do not replace the sandbox path with ordinary `os.run(env, ...)`. CraftOS can attach fallback access to host globals, which defeats capability isolation when globals such as `http`, `rednet`, or `peripheral` are intentionally omitted.

## Automation

`src/lib/automation.lua` owns automation state/logic. Configuration is persisted under `/data/automation.json`.

`src/apps/automation.lua` is the user-facing management application.

Automation runs as a background service in the main system process so rules continue to operate while the user navigates the dashboard.

## Redstone

`src/apps/redstone.lua` provides interactive redstone control.

Redstone is treated as a first-class system application rather than a one-off script, and automation may build on the same CC redstone capabilities.

## Networking architecture

Networking is implemented as project-specific layers over CC: Tweaked modem/rednet facilities.

The modules under `src/lib/net/` currently include:

```text
transport.lua
protocol.lua
peers.lua
pairing.lua
service.lua
address.lua
ccip.lua
routes.lua
router.lua
ip_service.lua
firewall.lua
ccdp.lua
datagram_service.lua
cctp.lua
stream_service.lua
```

A useful conceptual map is:

### Transport / base network

- `transport.lua` — CC modem/rednet transport boundary;
- `protocol.lua` — common message/protocol helpers;
- `peers.lua` — peer state;
- `pairing.lua` — pairing/trust workflow;
- `service.lua` — long-lived base network service.

### Addressing and routing

- `address.lua` — local/project address representation;
- `ccip.lua` — project IP-like packet layer;
- `routes.lua` — route state/table management;
- `router.lua` — routing logic;
- `ip_service.lua` — runtime service for the CCIP/routing layer.

### Datagram layer

- `ccdp.lua` — datagram protocol helper;
- `datagram_service.lua` — datagram runtime/service behavior.

### Stream layer

- `cctp.lua` — reliable stream/transport protocol helper;
- `stream_service.lua` — connection/stream runtime behavior.

CCTP has evolved to include sliding-window behavior. It is a project protocol inspired by transport-layer concepts, not real TCP compatibility.

### Policy/security

- `firewall.lua` — network policy/filtering.

User-facing network tools currently live in:

- `apps/network.lua`;
- `apps/routing.lua`;
- `apps/firewall.lua`.

## Security architecture

Security modules live under `src/lib/security/` and currently cover:

- integrity state/checking;
- long-lived security service;
- capability sandboxing.

The user-facing security UI is `src/apps/security.lua`; `src/apps/sandbox_probe.lua` exists for diagnostics.

The updater and rescue updater regenerate `/data/security/integrity.json` after installation so an intentional software update does not immediately look like tampering.

Network input and sandboxed-program input must be treated as untrusted. Validation belongs before indexing board/state tables, applying routes, executing actions, or exposing host capabilities.

## Games architecture

Games use the same runtime and UI foundations as system applications.

### Breakout

Entry point: `games/breakout.lua`.

Implementation modules:

- ball;
- paddle;
- bricks;
- renderer.

### Tetris

Entry point: `games/tetris.lua`.

Implementation modules:

- board;
- game;
- pieces;
- renderer;
- storage.

### Chess

Entry point: `games/chess.lua`.

The launcher exposes:

- `chess_local.lua` — local PvP;
- `chess_net.lua` — network PvP;
- `chess_tournament.lua` — tournament mode;
- `chess_spectator.lua` — read-only tournament spectator.

Core chess modules include:

- `board.lua`;
- `pieces.lua`;
- `move.lua`;
- `rules.lua`;
- `game.lua`;
- `renderer.lua`;
- `network.lua`;
- `tournament.lua`;
- `displays.lua`;
- `display_menu.lua`;
- `monitor_renderer.lua`.

The design separates chess rules/state from presentation and from network orchestration. Preserve that separation when adding features.

## Chess display model

Chess supports monitor-based spectator output in addition to the computer terminal UI.

Current display work includes:

- selecting multiple monitors;
- adaptive monitor rendering;
- hand-drawn/fixed-size piece glyphs for different monitor sizes;
- avoiding duplicated/stretched pieces on large monitors;
- tournament clocks and score on spectator displays.

Do not assume all attached monitors have identical dimensions or text scale. Renderer changes should be checked at compact and large monitor sizes.

## Deployment and update architecture

### `deploy.json`

Defines:

- release version;
- source-to-target mappings installed on CC computers.

Any new runtime dependency that must exist on installed computers must be added to this manifest.

### Normal update

`src/update.lua` downloads the manifest, compares each repository file with the installed copy, stages only changed files, then installs them and refreshes the integrity baseline.

The changed-file staging design is specifically intended to reduce temporary disk usage.

### Rescue update

`src/rescue_update.lua` is for low-space recovery. It avoids a staging copy, preflights net growth, and replaces changed files individually with verification/restoration logic.

Because it is a recovery tool rather than a normal installed component, do not automatically add it to `deploy.json` without a deliberate design decision.

## Data/state paths currently important

- `/.project-version` — installed release version;
- `/data/automation.json` — automation configuration;
- `/data/security/integrity.json` — integrity baseline;
- `/.cc_update_stage` — temporary normal-updater staging directory.

When adding persistent state, prefer `/data/...` and document ownership/migration expectations.
