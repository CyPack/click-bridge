# click-bridge — Architecture (agent-friendly reference)

> Goal: carry UI context from the browser (component, error, network, geometry) to a terminal AI
> coding agent with zero manual copy-pasting. Everything is local (127.0.0.1), everything stays on
> your machine.

## 1. Architecture Diagram

```
┌─ BROWSER (any of: dev-browser / your everyday browser) ────────────────────┐
│  your app (+ /snippet.js)              demo :7824                          │
│  • console error/warn buffer (25)      • BrokenZone test panel             │
│  • failed-request buffer (25)                                              │
│  • Alt+hover red outline                                                   │
│  • Alt+Click → payload                                                     │
└──────────────┬─────────────────────────────────────────────────────────────┘
               │ POST /click (localhost, CORS *)
               ▼
┌─ click-bridge server :7823 (systemd: click-bridge.service) ────────────────┐
│  stdlib Python · 127.0.0.1-only · 10 pytest tests                          │
│  • last.json  (ATOMIC write — most recent click)                           │
│  • history.jsonl (append-only event log)                                   │
│  • GET /snippet.js · /last · /health                                       │
└──────────────┬─────────────────────────────────────────────────────────────┘
               │ file read
               ▼
┌─ Claude Code hook layer (UserPromptSubmit, GLOBAL) ─────────────────────────┐
│  hooks/claude-code-inject.sh v3                                            │
│  • fresh (≤300s) + not-yet-consumed click → INJECTED into prompt context   │
│  • EXACTLY-ONCE: first session to submit a prompt gets it │ BROADCAST=1:   │
│    every session gets it once                                              │
│  • delivery.jsonl → which session received which click (instance tracking) │
└──────────────┬─────────────────────────────────────────────────────────────┘
               ▼
        Claude Code session(s) — N in parallel, one per project/monitor
               │ if deeper live analysis is needed (OPTIONAL layer)
               ▼
┌─ Live analysis MCP layer (optional) ────────────────────────────────────────┐
│  chrome-devtools MCP (its own chromium) · playwright MCP (fallback)         │
│  dev-browser :9222 (CDP attach — the window YOU are navigating)             │
└───────────────────────────────────────────────────────────────────────────┘
```

## 2. What Depends on What

| Layer | Dependency | Required? |
|---|---|---|
| Bridge core (server + snippet + hook) | Python 3 stdlib, bash, jq, systemd (user) | ✅ required — **NO MCP SERVER NEEDED** |
| chrome-devtools MCP (`chrome-devtools-mcp@latest`) | its own chromium instance | optional — deep network/perf inspection |
| playwright MCP | its own browsers | optional — devtools fallback + E2E verification |
| dev-browser (`tools/dev-browser.sh`) | chromium-browser, optional extension | optional — CDP :9222 + extension-loaded window |
| portal-screenshot (`tools/portal-screenshot.py`) | GNOME portal, PyGObject (`gi`) | optional — desktop visual context on GNOME Wayland |

## 3. Data Flow & File Lifecycle (`~/.click-bridge/`)

| File | Content | Lifecycle |
|---|---|---|
| `last.json` | FULL payload of the most recent click | atomic overwrite on every click; quarantined by self-heal if corrupt |
| `history.jsonl` | ALL clicks (append-only) | archived with gzip by self-heal above 50MB (never deleted) |
| `delivery.jsonl` | which session received which click, and when | append-only |
| `.consumed` / `.consumed-<hash>-<sid>` | delivery dedup markers | broadcast markers are swept after 2 hours |
| `_health.log` | self-heal detection/repair log | rotated at 1MB |
| `routes.json` | optional URL→project routing table (see § 8) | user-maintained |

## 4. Self-Healing (3 layers)

1. **systemd `Restart=on-failure`** — the server/demo process restarts immediately if it crashes.
2. **`click-bridge-heal.timer` (hourly + 5 min after boot, `Persistent=true`)** → `tools/self-heal.sh`:
   checks the services, the endpoint, the snippet, the hook registration, and a hook smoke test;
   REPAIRS what it can (restart, quarantine a corrupt JSON file, archive history), and logs what it
   can't to `_health.log` as `FAIL`.
3. **Test suite** — 10 pytest tests exercise the server against a real HTTP client on every change,
   so regressions in the core delivery path surface immediately.

## 5. Multi-Session Guide

- The hook is GLOBAL, so any number of parallel sessions can be running; the practical limit is RAM
  and your own rate limits, not the bridge.
- **Routing a click:** whichever session you type your next prompt into receives it (exactly-once).
  For broadcast delivery, start the session with `CLICK_BRIDGE_BROADCAST=1` set in its environment.
- **Common pattern:** one git worktree + one session per feature; all of them share the same bridge.
- **Observability:** `delivery.jsonl` (click→session mapping) tells you exactly which session
  consumed which click and when.

## 6. Security Boundaries

- The server and CDP bind to 127.0.0.1 only by default (an explicit `--bind` flag, or an auto-detected
  Tailscale address, are the only ways to widen that). The snippet must NEVER ship to a public
  production build — always gate it behind a dev-only check (see README § Integrating your app).
- Payload text fields are truncated (200 chars) before they're written to disk; the request body is
  capped at 256 KB server-side.
- If you use `tools/dev-browser.sh` with a third-party browser extension, vet that extension yourself
  before pointing `EXT` at it — the script only loads whatever path you give it.

## 7. Runbook (at a glance)

```bash
systemctl --user is-active click-bridge click-bridge-demo   # services
systemctl --user list-timers click-bridge-heal.timer        # self-heal timer
bash ~/projects/click-bridge/tools/self-heal.sh; echo $?    # manual heal run (0 = healthy)
tail ~/.click-bridge/_health.log                             # detection/repair history
~/projects/click-bridge/tools/dev-browser.sh                 # a browser window you can attach to
python3 -m pytest ~/projects/click-bridge/test_server.py -q  # 10 tests
```

## 8. Project Routing

`~/.click-bridge/routes.json` maps a click's URL host:port to a project directory. The hook compares
the session's `cwd` (from the hook's stdin JSON) against the matching route: if a route matches, ONLY
sessions whose `cwd` is under that project directory (this includes git worktrees, matched by prefix)
receive the click; if no route matches, the click is global. The routing check fails open — a routing
error never blocks delivery. This lets you run multiple unrelated projects' Claude Code sessions
side by side without one project's clicks leaking into another's context. See
`examples/routes.example.json` for the config format.
