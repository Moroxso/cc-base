# BASE Decision Log

This is a compact record of architectural decisions that are easy to lose across long development conversations. Current state belongs in `PROJECT_STATE.md`.

## D001 — Keep trusted and sandbox execution separate

Sandboxed applications use explicit environments and virtual storage. Do not use CraftOS `os.run` as a security boundary because environment fallback can expose host globals.

## D002 — `/data` is persistent state

Updates must preserve `/data`. Package/system ownership and protected system paths are distinct from user/runtime state.

## D003 — Immutable update payloads

Release manifests reference an immutable source commit and verify exact file bytes using git-blob SHA1. Hashing provides integrity/change detection, not publisher authenticity.

## D004 — Fleet relay is a dedicated role

Earlier Fleet builds let every ASSAULT relay packets. At scale this caused excessive forwarding/flooding. Only `RELAY` nodes forward mesh traffic now; workers remain endpoints.

## D005 — Replace one-shot timer job execution

Field tests showed turtles stuck indefinitely in `JOB:OUT` while remaining online. Simple local movement loops succeeded, isolating the problem to the old Fleet job event/timer executor. The runtime was changed to separated parallel worker/network/status loops. This is field-verified with fleets up to 18 units.

## D006 — Completion is job-ID correlated

Scheduler once displayed `DONE` while turtles were still physically working. Root cause was accepting a bare terminal `JOB_DONE` status without proving it belonged to the current run. A persistent `lastJob` completion ledger was added. Current completion requires matching `jobId` or a matching job event.

## D007 — Use slow adaptive load control

Polymania/server scheduling produces nonlinear performance and increasing per-worker timing variance as fleet size grows. A rapidly changing controller could create additional load and oscillation. Governor decisions therefore use long observation epochs, hysteresis and cooldowns; per-job step delay is not continuously changed.

## D008 — Benchmark rather than hard-code Fleet pacing

Manual tests produced different winners between delays such as 0.15 and 0.25 depending on server conditions. Automated repeated benchmarks and accumulated profiles are preferred over hard-coded assumptions.

Latest observed 18-unit profile currently favors delay 0.15 and AUTO concurrency, but confidence is still low and values remain recommendations.

## D009 — Treat global/interdimensional radio as observed, not guaranteed

Direct modem/rednet communication was repeatedly observed at >3000 blocks and across dimensions, and a modem-only computer discovered other distant modem computers. The known intentional range change was only about 64 -> 96 blocks, so the true cause of global delivery is uncertain. BASE retains DIRECT, MESH and AUTO transport modes; mesh must remain deployable if server behavior changes.

## D010 — Routers are future security gateways

Given a potentially global modem broadcast domain, routers are more valuable for authentication, ACL/firewall, service routing, QoS/rate limiting, audit and DDoS mitigation than for range extension. Endpoint enforcement remains mandatory because a router cannot stop raw physical transmissions from reaching another modem.

## D011 — Do not use industrial digging as raid breaching

Enemy/private claim protection blocks turtle digging, while turtle movement and attack against hostile players were field-confirmed to work. Industrial ENGINEER jobs target own/allied territory. Future RAID behavior should be movement/attack oriented and must not depend on dig/place bypassing claims.

## D012 — Keep Lua as host/HAL for future RISC-V

A server RISC-V VM is planned but specifications are unavailable. BASE should first define stable host ABI/syscalls and add RISC-V as an execution backend rather than prematurely rewriting CC:Tweaked integration away from Lua.

## D013 — Pointer-first local UI on Polymania

Pocket and ordinary-computer keyboard interaction is cumbersome in the current port. Starting with 0.23.0-alpha.5.4, Fleet applications use a shared pointer host: legacy/tested cores run in a child window and a clickable control panel handles mouse/touch input and numeric forms. Keyboard controls remain fallback. This avoids rewriting stable Fleet runtime logic solely for presentation changes.

## D014 — Keep project-context docs in `main`

The prior architecture/state/rules/decision documents lived on an old `docs/project-context-0.20.4.2` branch and became stale. From alpha5.4 onward the four reference Markdown files are maintained in `main` and updated with releases that materially change assumptions or verified state.
