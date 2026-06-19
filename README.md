# tmux-agent-state

Surface your AI coding agents' state — **working**, **blocked**, **idle** — directly
into tmux: a per-tab dot, a silent self-healing heartbeat, and an audible + visual
alert when an agent needs you or finishes a task you weren't watching.

Works with **opencode**, **pi**, **Claude Code**, and **Codex**. One canonical
vocabulary, one core, opt-in per agent.

```
 ● 1 editor    ● 2 claude    3 notes        ← orange dot = working, red dot = blocked
```

## Why

When you run agents across several tmux windows, you lose track of which one is
churning, which one is stuck waiting on a permission prompt, and which one finished
ten minutes ago. This puts that state where your eyes already are — the tab bar —
and beeps only for the agents you're **not** currently looking at.

## How it works

Every agent speaks a different event dialect. Instead of teaching tmux about each
one, each agent gets a thin **adapter** that normalizes its native events into a
single canonical vocabulary and calls one core script:

```
opencode / pi / claude / codex  →  agent-report.sh  →  tmux (dot + rollup + alert)
```

tmux only ever sees the core — it never knows which agent ran. Add a new agent by
writing one adapter; nothing else changes. (This is an anti-corruption layer.)

- **`agent-report.sh`** — the core. Maps a canonical state onto the pane, rolls the
  worst state up to the window (`blocked > working > idle`), and alerts only on a
  real transition into an attention state while the pane is **off-screen**.
- **`agent-status.sh`** — a silent heartbeat in `status-right`. Self-heals a stuck
  `blocked` once you're actually looking at that pane (no event fires when a prompt
  is cancelled, so the state would otherwise stick).
- **`agents.conf`** — the display layer: per-tab dot, status interval, visual bell.

## Install

```sh
git clone https://github.com/<you>/tmux-agent-state.git
cd tmux-agent-state

./install.sh --all          # core + every adapter whose tool is detected
# or pick exactly what you use:
./install.sh --with-opencode --with-claude
```

| Flag | Installs |
|------|----------|
| *(none)* | tmux core only (display + scripts) |
| `--with-opencode` | `~/.config/opencode/plugins/tmux-agent-state.js` |
| `--with-pi` | `~/.pi/agent/extensions/tmux-agent-state.ts` |
| `--with-claude` | merges hooks into `~/.claude/settings.json` |
| `--with-codex` | merges hooks into `~/.codex/hooks.json` |
| `--all` | every adapter whose tool dir exists |

Adapters are **opt-in** — the installer never touches the config of a tool you
didn't ask for. The Claude/Codex hook merge is idempotent and append-only: it adds
our hook without clobbering any hooks you already have.

The installer also appends a single `source-file` line to your tmux config
(`~/.config/tmux/tmux.conf` or `~/.tmux.conf`) so `agents.conf` loads **last** —
after your theme — letting the per-tab dot extend the theme's format instead of
overwriting it.

Then open a fresh tmux (or `tmux source-file ~/.config/tmux/tmux.conf`) and restart
your agents.

### Requirements

`tmux`, `jq`, `python3`, `bash`. (`jq` + `python3` power the Claude/Codex hook
adapters.) Sound is best-effort and optional — macOS uses `afplay`; Linux falls
back to `paplay` / `canberra-gtk-play` / `aplay` if present.

## Configuration

| Env var | Default (macOS / Linux) | Meaning |
|---------|-------------------------|---------|
| `AGENT_SOUND_BLOCKED` | `Funk.aiff` / `dialog-warning.oga` | played when an agent gets blocked |
| `AGENT_SOUND_IDLE` | `Glass.aiff` / `complete.oga` | played when a busy agent goes idle |
| `HERDR_ENV=1` | — | disables all adapters (lets [herdr] own the integration) |

The dot colors in `agents.conf` use the kanagawa palette
(`#e82424` blocked, `#dca561` working). Using another theme? Edit the hex values.

## Uninstall

```sh
./uninstall.sh
```

Removes the core, the source line, and the opencode/pi adapter files. Claude/Codex
hooks are stripped **by name** — anything else you configured stays.

## License

MIT — see [LICENSE](./LICENSE).
