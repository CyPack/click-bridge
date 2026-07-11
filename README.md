# click-bridge

**Alt+Click any element in your browser. Your terminal AI agent instantly knows what you're
pointing at — component name, source file:line, recent console errors, failed network requests,
and the box model — without you typing a word.**

A zero-dependency, stdlib-only local bridge that gives terminal coding agents (built and tested
against [Claude Code](https://claude.com/claude-code)) the same rich visual click-to-code context
that tools like v0 and Lovable give their in-browser chat panels — except it works with *any*
terminal agent workflow, on *your* stack, fully local.

- 🖱️ **Alt+Click capture** — component name, source `file:line`, CSS selector, text, box-model
- 🩺 **Automatic diagnostics** — last 10 console errors/warnings + last 10 failed network requests, captured for free
- ⚡ **Zero external dependencies** — Python stdlib + bash + `jq`, nothing to `npm install`
- 🔁 **Exactly-once delivery** across parallel agent sessions, with an opt-in broadcast mode
- 🗺️ **Project-aware routing** — clicks only reach sessions whose working directory matches the source project (git-worktree aware)
- 🌐 **Remote/Tailscale mode** — click from your phone or another machine on your tailnet, land in the same terminal session
- 🩹 **Self-healing** — systemd `Restart=on-failure` + an hourly detect-and-repair timer
- ✅ **10 passing tests**, real HTTP client against a real server, no mocks

---

## Why

Tools like [v0](https://v0.dev) and [Lovable](https://lovable.dev) popularized a very good idea:
click a UI element, and the AI editing your app instantly knows exactly which component you mean.
It's the fastest way to close the gap between "I see a bug" and "the agent has enough context to
fix it."

That workflow lives entirely inside those tools' own hosted chat UI. If you work the way most
professional developers do — a real terminal, a real editor, a real coding agent running against
your own repo — you don't get it. You're back to describing UI bugs in prose ("the card in the
top-right, the one with the badge, no not that one...") or manually digging up file paths yourself.

click-bridge closes that gap for terminal agents. Alt+Click something in your running app, and the
next prompt you send to your agent already has the component, its source location, and — critically
— *why* it might be broken (recent console errors, failed requests) sitting right there in context.

## How it works

```
BROWSER (your app + /snippet.js)
   │  Alt+Click → {component, source:{file,line}, selector, box, console_errors, failed_requests, ...}
   ▼
POST http://127.0.0.1:7823/click
   ▼
click-bridge server (stdlib Python, 127.0.0.1-only)
   │  atomic write                     append
   ▼                                     ▼
~/.click-bridge/last.json          ~/.click-bridge/history.jsonl
   │
   ▼
Claude Code UserPromptSubmit hook (hooks/claude-code-inject.sh)
   │  fresh (≤300s) + not yet delivered → injected into your next prompt
   ▼
Your agent sees: component, file:line, console errors, failed requests, box model
```

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full diagram (including the optional
live-analysis MCP layer), the dependency matrix, the file lifecycle table, and the security model.

## Quickstart (60 seconds)

```bash
git clone https://github.com/CyPack/click-bridge.git
cd click-bridge

# 1. start the bridge server (binds 127.0.0.1:7823 by default)
python3 server.py &

# 2. serve the demo page anywhere, e.g.:
python3 -m http.server 7824 --directory demo &

# 3. open http://127.0.0.1:7824/ in your browser, hold Alt, and click a card
```

You should see a toast in the browser (`→ Claude Code ✓ TaskCard`) and a fresh
`~/.click-bridge/last.json`. Now wire up the Claude Code hook (next section) and the *next prompt*
you send in your terminal will already contain that context.

## Claude Code integration

Add a `UserPromptSubmit` hook to your Claude Code `settings.json` (global: `~/.claude/settings.json`,
or per-project: `.claude/settings.json`):

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/projects/click-bridge/hooks/claude-code-inject.sh"
          }
        ]
      }
    ]
  }
}
```

(Adjust the path to wherever you cloned this repo.)

**What gets injected.** If `~/.click-bridge/last.json` is fresh (≤300 seconds old) and hasn't
already been delivered to a session, the hook prepends a `[CLICK-BRIDGE]` block to your prompt
containing the full click payload, followed by a fixed **priority protocol** telling the agent how
to use it:

1. `component` + `source` (file:line) → go straight to the relevant code
2. `console_errors` non-empty → analyze the errors first (the root cause is usually there)
3. `failed_requests` non-empty → check the backend/endpoint/network issue
4. `box` (padding/margin/size) → use for visual/layout complaints

This ordering matters: an agent that jumps straight to "let me fix the CSS" when the real problem
is a 500 from `/api/tasks` wastes a turn. The protocol steers it to the console/network evidence
before the geometry.

## Integrating your app

The fastest path — one script tag, dev-only:

```html
<script src="http://127.0.0.1:7823/snippet.js"></script>
```

**⚠️ Never ship this to a production build served to the public.** Gate it behind a dev-only check.

**Dev-server guard** (Vite/Next/CRA-style apps where the snippet is only ever bundled in dev):

```js
if (import.meta.env.DEV) {                 // Vite
// if (process.env.NODE_ENV === 'development') {  // Next.js / webpack
  const s = document.createElement('script');
  s.src = `http://${location.hostname}:7823/snippet.js`;
  document.body.appendChild(s);
}
```

**Hostname guard** (for apps that build to a static `dist/` and serve that same bundle in every
environment — `import.meta.env.DEV` is `false` once built, so guard on the serving host instead):

```js
const isLocalOrTailnet =
  location.hostname === 'localhost' ||
  location.hostname === '127.0.0.1' ||
  /^100\.\d+\.\d+\.\d+$/.test(location.hostname) ||   // Tailscale CGNAT range
  location.hostname.endsWith('.ts.net');               // Tailscale MagicDNS
if (isLocalOrTailnet) {
  const s = document.createElement('script');
  s.src = `http://${location.hostname}:7823/snippet.js`;
  document.body.appendChild(s);
}
```

This guarantees the snippet only ever loads when the page is being served to you, on your machine
or your tailnet — never to a visitor on a real public domain.

**Attributes the snippet reads**, in priority order — set these on any element to control what gets
reported:

| Attribute | Purpose |
|---|---|
| `data-component` | component name (falls back to the React fiber's display name, then the tag name) |
| `data-file` | source file path |
| `data-line` | source line number |

**Exact file:line for React, with zero manual attributes** — install
[react-dev-inspector](https://github.com/zthxxx/react-dev-inspector) (dev-only) and forward its
callback to the bridge:

```tsx
import { Inspector } from 'react-dev-inspector'

{import.meta.env.DEV && (
  <Inspector
    keys={['alt', 'c']}
    onClickElement={(el) => {
      fetch('http://127.0.0.1:7823/click', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          component: el.name,
          source: { file: el.codeInfo?.absolutePath ?? el.codeInfo?.relativePath, line: el.codeInfo?.lineNumber },
          url: location.href,
        }),
      }).catch(() => {})
    }}
  />
)}
```

## Multi-session & routing

Run as many parallel Claude Code sessions as you want — the hook is global and every session polls
the same `~/.click-bridge/last.json`.

- **Exactly-once (default):** a click is delivered to whichever session's *next prompt* is submitted
  first. Other sessions never see it — no duplicate context, no noise.
- **Broadcast:** set `CLICK_BRIDGE_BROADCAST=1` in a session's environment before starting it, and
  that session (and every other broadcast-enabled session) receives every click once.
- **Project routing:** drop a `~/.click-bridge/routes.json` (see
  [`examples/routes.example.json`](examples/routes.example.json)) mapping `url_contains` fragments
  (e.g. a dev-server port) to a project directory. Clicks whose URL matches a route are only
  delivered to sessions whose `cwd` starts with that project path — this includes git worktrees,
  matched by directory prefix, so feature-branch worktrees of the same project still receive their
  project's clicks. Unmatched clicks stay global. The routing check fails open: any error in
  evaluating `routes.json` falls back to delivering the click, so a bad config never silently
  blocks the bridge.
- All deliveries are logged to `~/.click-bridge/delivery.jsonl` (session id, click hash, age) so you
  can audit exactly who got what.

## Remote / Tailscale mode

`server.py` auto-detects your [Tailscale](https://tailscale.com) IPv4 address (`tailscale ip -4`)
and binds to it alongside `127.0.0.1`, with no extra flags — so a click from your phone's browser
or another machine on your tailnet lands in the exact same `last.json` your terminal session reads.

The snippet targets `location.hostname` dynamically (see `snippet/click-bridge.js`), so the same
`<script>` tag works whether the page is served from `127.0.0.1`, a `100.x.y.z` Tailscale address,
or a `*.ts.net` MagicDNS name — no dual-URL config needed on the browser side. Use the hostname
guard shown above to make sure the snippet only ever activates on those trusted hosts.

Disable auto-binding with `--no-tailscale`, or pin exact addresses with one or more `--bind` flags:

```bash
python3 server.py --no-tailscale                  # 127.0.0.1 only
python3 server.py --bind 127.0.0.1 --bind 100.64.0.5  # explicit addresses
```

## systemd install (Linux, user units)

```bash
mkdir -p ~/.config/systemd/user
cp systemd/*.service systemd/*.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now click-bridge.service click-bridge-demo.service click-bridge-heal.timer
```

The unit files use the systemd `%h` specifier (your home directory) instead of a hard-coded path,
so they work for any user without editing — as long as you cloned this repo to
`~/projects/click-bridge`. If you cloned it elsewhere, edit the `ExecStart=`/`WorkingDirectory=`
lines accordingly.

## Self-healing

`click-bridge-heal.timer` runs `tools/self-heal.sh` hourly (plus 5 minutes after boot). It checks:
data-directory writability, a corrupt `last.json` (quarantined, not deleted), whether the services
are active (restarted if not), whether `/health` actually responds, whether `/snippet.js` serves
correctly, whether the Claude Code hook is still registered in `settings.json`, a hook smoke test,
and `history.jsonl` bloat (archived with gzip above 50MB, never deleted). Everything it finds or
fixes is logged to `~/.click-bridge/_health.log`; run it manually any time with:

```bash
bash tools/self-heal.sh; echo $?   # 0 = healthy/repaired, 1 = needs your attention
```

## Security model

- **Binds to `127.0.0.1` (plus an optional auto-detected Tailscale address) — never `0.0.0.0`.**
  There's no flag that binds to all interfaces by accident.
- **CORS is wide open (`Access-Control-Allow-Origin: *`)** — this is safe *specifically because* the
  server only listens on localhost/tailnet addresses. Any origin can POST to it, but only a process
  running on your machine (or your tailnet) can reach the port in the first place.
- **Never ship `snippet.js` to a public production host.** It executes arbitrary DOM introspection
  on every Alt+Click and phones home to `:7823`. Always gate it with a dev-only or hostname guard
  (see § Integrating your app).
- **256 KB request body cap** — oversized POSTs are rejected with `413` before they're parsed.
- **Payload text is truncated** — element `text`, console messages, and request URLs are all capped
  (200–300 chars) before being written to disk, limiting how much arbitrary page content ever lands
  in `history.jsonl`.
- **The data directory is created `0o700`** (owner-only) on first run.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| No toast appears on Alt+Click | server not running | `python3 server.py &` or check `systemctl --user status click-bridge` |
| Toast says "click-bridge unreachable" | wrong port/host, or a firewall | confirm `curl http://127.0.0.1:7823/health` returns `{"ok":true,...}` |
| Hook doesn't inject anything | click older than 300s, or already delivered to another session | Alt+Click again; check `~/.click-bridge/delivery.jsonl` |
| Hook injects nothing in *any* session | hook not registered, or `jq`/`python3` missing | `grep claude-code-inject.sh ~/.claude/settings.json`; run `echo '{}' \| hooks/claude-code-inject.sh` manually |
| Click never reaches the right session | project routing sending it elsewhere | check `~/.click-bridge/routes.json` and the session's `cwd` |
| `component` is just a tag name (e.g. `div`) | no `data-component` attribute and no React fiber found | add `data-component="MyComponent"`, or install react-dev-inspector |
| `source` is `null` | no `data-file`/`data-line`, and React build has no `_debugSource` | see FAQ below (minified/production React builds, React 19) |
| `history.jsonl` growing unbounded | self-heal timer not installed/running | `systemctl --user enable --now click-bridge-heal.timer` |

## Testing

```bash
python3 -m pytest test_server.py -q
```

10 tests, run against a real `ThreadingHTTPServer` instance via `http.client` — no mocks, no test
doubles for the HTTP layer.

## FAQ

**Why is `component` showing minified names like `t6` instead of my component's real name?**
Production React builds (and some dev builds run through a minifier) strip `displayName`/`name`
from function components. Set `data-component` explicitly on elements you care about, or make sure
you're running an unminified dev build.

**Why is `source` always `null` on React 19?**
React 19 removed `_debugSource` from the fiber tree entirely (it now relies on the compiler /
source-map based tooling instead). Use `data-file`/`data-line` attributes, or the
react-dev-inspector integration, which gets exact file:line from Babel-injected metadata rather
than the fiber.

**Does it work inside an `<iframe>`?**
Only if the snippet is loaded inside the iframe's own document — `document`/`window` in the snippet
are scoped to whichever document it's injected into. A parent-page script tag will not see clicks
inside a same-origin *or* cross-origin iframe's content.

## License

[MIT](LICENSE) © 2026 CyPack
