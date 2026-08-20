# cc-base — Project State

> Canonical context anchor for future development sessions. Keep this file short, factual, and current.

## How to use this file

At the start of a new development chat/session:

1. Read `PROJECT_STATE.md`.
2. Read `deploy.json` to confirm the current release version and deployed file set.
3. Read only the source files relevant to the task; do not reconstruct code from chat memory.
4. Use `ARCHITECTURE.md` for stable subsystem boundaries.
5. Use `DEVELOPMENT_RULES.md` for invariants and constraints.
6. Use `DECISION_LOG.md` only when historical rationale is needed.

If documentation conflicts with the repository, the actual code on the active GitHub branch and `deploy.json` win. Correct the documentation as part of the same work.

## Project identity

`Moroxso/cc-base` is an OS-like integrated software environment for CC: Tweaked computers, developed for the server-side CC: Tweaked environment used in the Polymania modpack.

The project is not intended to be a collection of unrelated Lua scripts. The direction is a coherent computer environment with:

- boot/startup and a main dashboard;
- reusable GUI/runtime libraries;
- applications such as Redstone Control and Automation;
- a custom networking stack and network-management applications;
- security/integrity/sandbox facilities;
- games that use the same runtime/UI/network foundations;
- GitHub-driven deployment and self-update tooling.

It runs on top of CraftOS/CC: Tweaked APIs, so “OS” here means the project’s integrated userspace/system layer rather than replacement of the underlying CraftOS kernel/runtime.

## Current canonical snapshot

- Release version: **0.20.4.2** (`deploy.json`).
- Snapshot branch when this file was created: `main`.
- Snapshot HEAD: `895771b8582f67559e8149acba215e5a40b05e1f` (`Update rescue_update.lua`).
- Current development point: **after stabilization of Chess Tournament Mode**.
- Latest work after Tournament Mode: updater disk-space hotfixes and the low-space rescue updater.
- Next major feature/task: **not specified yet**. Do not invent one from historical context.

The snapshot commit above is informational only. On future sessions, query GitHub again and do not assume it is still HEAD.

## Current major subsystems

### System shell

`src/startup.lua` starts `/main.lua` and leaves the machine in a recoverable terminal state if boot fails.

`src/main.lua` is the main dashboard and concurrently runs the long-lived system services for automation, base networking, IP/routing, datagrams, streams, and security.

### UI/runtime

Reusable components live under `src/lib/gui/` plus `src/lib/ui.lua` and `src/lib/input/`.

`src/lib/runtime.lua` supports trusted execution and capability-sandboxed execution.

### Applications

Current deployed applications include:

- Redstone Control;
- Automation;
- Network Control;
- Routing;
- Firewall;
- Security;
- sandbox diagnostic probe.

### Networking

The network layer under `src/lib/net/` includes modem/rednet transport, protocol helpers, peer discovery/trust/pairing, addressing, routing, firewall policy, CCIP, datagram service/CCDP, and stream service/CCTP.

Treat this as project-specific networking layered over CC: Tweaked primitives, not as a claim of wire compatibility with real-world IP/TCP.

### Security

The project currently has integrity checking, a security service, firewall policy, and a capability sandbox. Update operations refresh the integrity baseline after a successful installation.

A critical sandbox invariant is that sandboxed programs must not use `os.run` with an incomplete environment, because CraftOS environment fallback can expose host globals. The current runtime deliberately uses `loadfile(..., env)` for sandbox execution.

### Games

Current deployed games are Breakout, Tetris, and Chess.

Chess has four user-facing modes:

- Local PvP;
- Network PvP;
- Tournament;
- Tournament Spectator (read-only).

The chess implementation is split into board/pieces/move/rules/game/rendering/network/tournament/display modules. Tournament work also introduced adaptive multi-monitor spectator output, clocks, score display, and monitor-oriented piece rendering.

## Tournament Mode status

Tournament Mode was released as `0.20.4` after the following functional progression:

- tournament state and clocks;
- tournament-aware chess protocol/state synchronization;
- tournament HUD score/clocks;
- network tournament mode;
- read-only spectator client;
- tournament clocks/scoreboard on spectator monitors;
- launcher integration for Tournament and Spectator modes.

For future work, treat Tournament Mode as an existing stabilized feature unless a newly reported bug shows otherwise.

## Update and recovery status

### Normal updater — `src/update.lua`

The normal updater:

- downloads `deploy.json` from GitHub;
- compares downloaded content with installed files;
- stages only files that actually changed;
- reserves a small amount of free space before staging each changed file;
- installs staged files only after downloads complete;
- removes failed staging data;
- writes `/.project-version`;
- refreshes `/data/security/integrity.json`.

This behavior was introduced to avoid requiring a second full copy of the installation during update.

### Low-space rescue updater — `src/rescue_update.lua`

`rescue_update.lua` is an out-of-band recovery utility and is currently **not listed in `deploy.json`**.

It is intended for machines that cannot afford normal staging. It:

- removes stale update staging data;
- performs a preflight pass to determine changed files and net installation growth;
- sorts replacements to reduce peak space pressure;
- downloads and replaces changed files one at a time;
- verifies size/hash between preflight and install;
- attempts to restore the previous file if a replacement fails;
- updates the version file and integrity baseline afterward.

Historical note: early rescue-updater revisions had a syntax problem around the later part of the file and were corrected in subsequent GitHub commits. Do not assume that old syntax error exists in current `main`; always fetch the current file.

## Server/environment constraints observed during development

These are observations from the Polymania server environment, not eternal configuration constants:

- CC: Tweaked computer storage was observed with a `computer_space_limit` of approximately **1,000,000 bytes**.
- A request/planned server configuration increase to approximately **8,000,000 bytes** was discussed.
- After deleting failed update/staging remnants, one affected computer had about **498,081 bytes** free.
- Low disk space was sufficient to make the previous update strategy impractical and motivated the current changed-file staging and rescue update paths.

Re-check actual server configuration/free space before relying on these values.

## Known unknowns / do-not-assume list

Do not infer any of the following without checking code, GitHub history, or a new user report:

- the next planned feature after Tournament Mode;
- that the server disk quota has already been raised to 8 MB;
- that a historical updater/rescue-updater error is still present;
- that every CC computer has a modem, HTTP access, monitor, or identical terminal dimensions;
- that all network peers are trusted;
- that `main` has not changed since the snapshot SHA above.

## Maintenance rule

Update this file whenever one of these changes:

- release version;
- active development milestone;
- a major subsystem is added/removed;
- an important environment constraint changes;
- a critical invariant or known blocker changes.

Prefer replacing stale facts over appending a long diary. Historical rationale belongs in `DECISION_LOG.md`.
