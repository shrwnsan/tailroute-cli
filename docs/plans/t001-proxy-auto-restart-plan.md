# T-001 Proxy Health Monitoring & Auto-Restart — plan (2026-11-14)

Implements the ratified eval-005 default: 30s health checks, max 3 restarts
per 60s, exponential backoff 5s→10s→20s, daemon owns restarts, app
display-only, built on existing health primitives.

## Unknowns / assumptions

- **A1 (conservative reading):** the monitor only *keeps a running proxy
  alive*; it never auto-starts a proxy the user did not start, and never
  stops one the user stopped. Start/stop semantics stay exactly as today.
  This avoids smuggling in the "VPN active → daemon starts proxy" behavior
  change that the help text implies but reconcile has never implemented.
- **A2:** restart works headless after first auth (tsnet persists identity
  in the state dir; TS_AUTHKEY only needed on first run).
- **A3 (deviation, safe direction):** restart-loop guard *disables and
  surfaces*; it does NOT remove the proxy binary (March text said remove —
  rejected: root deleting a user binary is a worse failure than a stopped
  proxy).

## Approach

- New `bin/lib-proxy-monitor.sh`, sourced by `lib-event-loop.sh`.
- Tick hook in its own background poll subshell at the ratified 30s cadence
  (mirrors start_poll's trap/wait structure; chosen over hooking the 60s
  safety-net poll so the pinned poll machinery stays untouched).
- Desired-state detection: PID file + `kill -0` + port probe. Proxy counts
  as "was running" if a live pid was seen at the previous tick; the monitor
  restarts only in that case.
- Restart: as the target console user (reuse existing target-home/uid
  resolution), detached so the daemon's EXIT trap cannot reap it; log every
  restart with timestamps via lib-log.
- Loop guard: >3 restarts in any 60s window → enter `disabled` state, stop
  restarting, surface loudly. Manual `tailroute proxy start` clears it.
- State persisted (`~/.tailroute/proxy-monitor.state`) so `proxy status` and
  `tailroute status` (user CLI, read-only) show: healthy / restarting
  (next attempt in Ns) / disabled (restart loop).
- App changes: none (display-only rule; the app already renders CLI status).

## Risks

- Root spawning a user-context process from the daemon (pid file ownership,
  env, detachment) — verify the restarted proxy survives daemon exit and is
  owned by the console user.
- Poll-tick timing interplay with the existing reconcile re-assert gate.
- Restart while port still held by a dying process → readiness probe loop
  (reuse do_proxy_start's nc-wait pattern).

## Verification

- `bash tests/run-tests.sh` in the worktree — all pass, including new
  `tests/test-lib-proxy-monitor.sh` (kill→restart, backoff sequence, 3-in-60
  give-up → disabled, manual start clears disabled, never auto-starts).
- `shellcheck` on new/changed files (run-tests runs it).
- Manual host check at the end: start proxy, `kill` it, observe restart in
  logs and `proxy status` output (documented in PR, not run as root builds).
