# cc-base — Development Rules

This file exists to reduce context drift and hallucinations in long AI-assisted development sessions.

## 1. Source-of-truth rules

Before changing code:

1. Fetch current GitHub `main` (or the explicitly active branch).
2. Read `PROJECT_STATE.md`.
3. Read `deploy.json`.
4. Read the complete current contents of every file that will be changed.
5. Read directly related modules/interfaces before altering their contracts.

Never recreate a current source file from remembered chat text when GitHub is available.

If chat history and GitHub disagree, prefer current repository state unless the user explicitly says an uncommitted/local version is authoritative.

Do not assume the snapshot commit written in `PROJECT_STATE.md` is still current.

## 2. Keep context modular

Use the context files for different purposes:

- `PROJECT_STATE.md` — current version, milestone, constraints, blockers;
- `ARCHITECTURE.md` — stable subsystem map;
- `DEVELOPMENT_RULES.md` — invariants and working rules;
- `DECISION_LOG.md` — historical reasons and milestone evolution.

Do not turn `PROJECT_STATE.md` into a full changelog. Remove stale current-state claims instead of accumulating contradictory notes.

## 3. Platform assumptions

Target platform is CC: Tweaked on the Polymania server/modpack environment.

Use CC: Tweaked/CraftOS APIs and event semantics. Do not assume availability of ordinary desktop Lua facilities, POSIX paths, sockets, threads, or unrestricted filesystem capacity.

Features must degrade sensibly when relevant peripherals/services are absent. Examples:

- no modem/rednet;
- no HTTP access;
- no external monitor;
- small terminal;
- resized terminal;
- limited storage.

Do not assume all server configuration values are permanent. Re-check limits when a task depends on them.

## 4. Disk-space discipline

Storage capacity is a real production constraint.

Observed during development: server computers were limited to roughly 1,000,000 bytes, and an increase to roughly 8,000,000 bytes was discussed but must not be assumed complete.

Rules:

- avoid temporary full-installation copies;
- compare before writing where practical;
- clean temporary data after failure;
- account for peak space, not only final file size;
- preserve existing installation where a failed update can be made non-destructive;
- use `rescue_update.lua` when normal staging cannot fit;
- re-check free space before diagnosing an update failure as a code bug.

Do not casually add large assets or duplicated generated data to the deployment.

## 5. Deployment manifest discipline

`deploy.json` is part of every release contract.

When adding, renaming, or removing a file required on installed computers, update `deploy.json` in the same change.

Do not add development-only or out-of-band recovery utilities to the manifest automatically. `src/rescue_update.lua` is currently intentionally not deployed by the normal updater.

Version rules:

- do not bump the release number merely because code was edited;
- bump `deploy.json.version` when the work is intentionally being released/hotfixed;
- use the existing version lineage rather than inventing a new scheme without discussion;
- after an update, `/.project-version` should match the manifest version.

## 6. Updater invariants

Normal updater invariants:

- validate manifest entries;
- stage only changed files;
- clean staging after failure;
- do not intentionally delete the working installation before a valid replacement is available;
- refresh the security integrity baseline after success.

Rescue updater invariants:

- no normal staging copy;
- preflight changed files and net growth;
- verify repository content between preflight/install;
- replace incrementally;
- attempt restoration on failed replacement;
- update version and integrity baseline only as part of a coherent completed recovery.

When updater behavior changes, test both normal and low-space paths conceptually; do not optimize one by silently breaking the other.

## 7. Security invariants

Treat network messages, persisted configuration, and sandboxed programs as untrusted input.

Validate structure, type, ranges, coordinates, addresses, and state transitions before indexing tables or applying actions.

Capability sandbox isolation is security-sensitive. Preserve the explicit-environment `loadfile` execution model unless a replacement is proven not to leak host globals.

Do not expose `http`, `rednet`, `peripheral`, filesystem access, or other host capabilities to sandboxed code unless the selected sandbox profile intentionally grants them.

An intentional update must refresh the integrity baseline so the security service distinguishes authorized software updates from later modification.

## 8. Networking invariants

The CCIP/CCDP/CCTP stack is project-specific. Do not silently replace it with raw rednet shortcuts inside higher-level features when the existing abstraction can support the use case.

Preserve layer boundaries where practical:

- transport/base network;
- peers/pairing/trust;
- addressing/routing;
- datagrams;
- streams;
- firewall/policy;
- application protocol.

Network applications and games must handle malformed/stale/duplicate/unexpected messages without blindly mutating state.

Do not claim compatibility with real IP/UDP/TCP unless such compatibility is explicitly implemented and tested.

## 9. UI rules

The UI is terminal/peripheral constrained.

For interactive programs:

- support keyboard navigation where the surrounding UI does;
- keep mouse support where already present;
- redraw correctly after `term_resize` where feasible;
- avoid coordinates that only work on one terminal size;
- preserve a clear back/exit path;
- restore sensible terminal colors/state after exit or failure.

For monitor rendering:

- test reasoning against at least a compact and a large monitor layout;
- do not stretch piece glyphs by naive character replication if that produces duplicate-looking sprites;
- keep game state separate from monitor presentation.

## 10. Chess invariants

Chess rules/state logic should remain separate from local UI, network orchestration, tournament state, and spectator rendering.

Current user-facing modes are Local PvP, Network PvP, Tournament, and read-only Tournament Spectator.

Tournament/spectator invariants:

- spectator clients are read-only with respect to match state;
- clocks and score must derive from authoritative tournament state;
- network move coordinates/state must be validated before board access;
- black-side orientation must not alter canonical board state;
- monitor output must not mutate gameplay state.

Tournament Mode is considered stabilized at the current project checkpoint. Do not rewrite it wholesale unless a concrete requirement/bug justifies that scope.

## 11. Change-scope discipline

Prefer the smallest coherent change that satisfies the task.

Avoid opportunistic rewrites of unrelated modules during bug fixes.

When a cross-cutting change is necessary, state which contracts are changing and inspect every known caller before implementation.

Preserve backward-compatible data formats/protocol fields when feasible. If migration is necessary, document it explicitly.

## 12. Verification checklist

Not every environment can run automated tests, so verification should combine static inspection with in-game testing.

For relevant changes, check:

- Lua syntax/load errors;
- boot path (`startup.lua` -> `main.lua`);
- dashboard launch/return behavior;
- terminal resize/small-screen handling;
- missing peripheral/modem/HTTP behavior;
- persistence read/write behavior;
- updater free-space behavior and cleanup;
- integrity-baseline refresh;
- malformed network input;
- host/join/disconnect/reconnect paths for network features;
- chess local/network/tournament/spectator separation;
- spectator read-only behavior;
- tournament clocks/score synchronization;
- compact and large monitor rendering when display code changes.

When something has not been tested on the actual server, say so. Do not convert static confidence into a claim of runtime verification.

## 13. Documentation update rule

After a major feature or release:

- update `PROJECT_STATE.md` with the new current state;
- update `ARCHITECTURE.md` only if subsystem boundaries changed;
- add a short entry to `DECISION_LOG.md` when the change establishes a durable design decision;
- update this file only when an invariant/workflow rule changes.

The goal is that a fresh chat can recover the project correctly by reading a small amount of repository text instead of the entire historical conversation.
