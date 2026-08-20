# cc-base — Decision Log

This is a concise record of durable architectural/product decisions and major milestones. It is not a complete changelog.

Use GitHub commit history for exact implementation chronology.

## Product direction

### Integrated system, not isolated scripts

The project direction is an OS-like integrated environment for CC: Tweaked computers in the Polymania server/modpack environment.

Applications, games, networking, security, automation, UI, runtime, and update behavior should share reusable infrastructure instead of growing as independent one-off scripts.

### GitHub is the deployment source

`deploy.json` defines the release version and installed file set. Runtime machines update from the GitHub repository.

This makes repository state part of the operational system, not only a development archive.

## Major evolution

The release history shows the following progression.

### 0.6.0 — Redstone Control

Redstone became a first-class system application.

### 0.9.x–0.10.0 — Automation

The system gained automation features, including timed automation, moving from interactive-only controls toward persistent background behavior.

### 0.12.1 — Input/UI refinement

Key-repeat support was added, reinforcing reusable UI/input infrastructure rather than per-app ad hoc handling.

### 0.14.x–0.15.x — Games and chess UI

Tetris received polish and Chess became an increasingly structured application with reusable game/rendering modules.

### 0.16.1–0.16.2 — Network Core pairing/trust

Peer pairing/trust persistence became part of the network core. Trust state is therefore an architectural concern, not merely an application setting.

### 0.18.1 — CCTP sliding window

The project’s reliable stream protocol evolved beyond simple request/reply behavior toward windowed transport semantics.

### 0.18.2 — CCIP routing

Routing became a dedicated layer of the custom network stack.

### 0.19.0 — Firewall and security policies

Network policy/security moved into explicit subsystem boundaries.

### 0.19.1–0.19.2 — Integrity protection

The project added an integrity guard and subsequent path fixes. Software updates therefore need to maintain a valid integrity baseline.

### 0.19.3–0.19.4 — Capability sandbox

A sandboxed runtime was introduced and then hardened for isolation.

Durable decision: sandbox isolation must use a genuinely isolated explicit environment. Ordinary `os.run` environment fallback is not acceptable for capability security because omitted host globals can become reachable.

### 0.20.0 — Network Chess

Chess expanded from local play to multiplayer over the project networking stack.

Durable decisions established during this stage include:

- local and network modes remain separate behind a launcher;
- multiplayer uses the project’s CCTP/network helpers rather than bypassing the stack;
- board orientation is presentation state, not canonical game-state mutation;
- received move coordinates are validated before board access.

### 0.20.1–0.20.3 — Multi-monitor spectator rendering

Chess gained spectator monitor output and then multiple rounds of rendering refinement.

The evolution from scaled/stretched sprites to fixed/adaptive hand-drawn glyphs established an important rendering principle: CC monitor layouts should be designed for their actual character geometry rather than simulated by naive scaling.

Multi-monitor selection/management became reusable chess display infrastructure.

### 0.20.4 — Tournament and Spectator Mode

Tournament state/clocks, protocol extensions, score/HUD support, network tournament play, read-only spectator mode, and scoreboard/clock monitor output were integrated and released.

Durable decisions:

- tournament state is distinct from ordinary chess board state;
- spectators consume state but do not control the match;
- clocks and score are part of authoritative tournament state;
- tournament display output is separated from match-state mutation;
- Local, Network, Tournament, and Tournament Spectator remain explicit user-facing modes.

Current project checkpoint treats Tournament Mode as stabilized.

### 0.20.4.1–0.20.4.2 — Update system under storage pressure

The Polymania server environment exposed a practical CC computer disk-space problem. A full or overly large staging strategy could fail even when the final installation itself fit.

The normal updater was changed to stage only files whose installed contents differ from GitHub, and failed staging is cleaned automatically.

Durable decision: updater design must account for **peak temporary disk use**, not only final installation size.

A separate low-space `rescue_update.lua` was added for machines that cannot afford normal staging.

Durable rescue-update decisions:

- treat it as an out-of-band recovery utility rather than a normal installed component;
- preflight changes and net growth first;
- replace changed files one at a time;
- verify repository content across preflight/install;
- attempt restoration if replacement fails;
- refresh version/integrity metadata at the end.

Early rescue-updater revisions required follow-up fixes, including a syntax correction. Future sessions must inspect the current GitHub file instead of repeating the historical error report as if it were current.

## Environment decisions and observations

### Server storage limits are operational constraints

During the updater incident, CC computer storage was observed at about 1,000,000 bytes total capacity, with discussion of increasing `computer_space_limit` to about 8,000,000 bytes.

This is recorded as an environment observation, not a permanent requirement. The code should remain reasonably space-efficient even if the server quota is raised.

### Design for heterogeneous CC peripherals

The project has repeatedly needed to handle varying terminal/monitor sizes and optional network/peripheral availability.

Durable principle: do not design the system around one physical CC computer layout.

## Current unresolved product decision

No next major feature after the stabilized Tournament Mode checkpoint is recorded yet.

Future assistants/developers must not infer a roadmap item from commit history alone. The next task should come from a new explicit requirement, bug report, or user decision.

## How to add entries

Add an entry only when a change creates durable context that would otherwise be easy to lose, such as:

- a subsystem boundary;
- a security invariant;
- a protocol/data compatibility decision;
- an operational constraint that shaped architecture;
- a major user-facing mode or product direction.

Routine bug fixes belong in Git history, not here.
