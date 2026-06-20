# tmux-agent-state

**Know which AI agent needs you — without leaving your tab bar.**

Run agents across tmux windows and a colored dot tells you each one's state at a
glance. A sound fires only when an agent you're **not** watching gets blocked or
finishes. No more cycling through panes to check who's stuck.

```
  ● 1 api      ● 2 claude      3 notes
  └ working    └ blocked       └ idle
  (orange)     (red, beeps)    (no dot)
```

Works with **opencode**, **pi**, **Claude Code**, and **Codex** — one shared core,
each agent opt-in.

---

## Quick path

```sh
git clone https://github.com/Gentleman-Programming/tmux-agent-state.git
cd tmux-agent-state
./install.sh --all          # core + every agent you have installed
```

Then open a fresh tmux (or `tmux source-file ~/.config/tmux/tmux.conf`) and restart
your agents. That's it.

Want only some agents? Pick them explicitly:

```sh
./install.sh --with-opencode --with-claude
```

---

## What the dots mean

| Dot | State | Meaning | Alert when off-screen |
|-----|-------|---------|------------------------|
| 🟠 orange | `working` | agent is churning | — |
| 🔴 red | `blocked` | waiting on YOU (permission / question) | sound + flash |
| *(none)* | `idle` | done, or not running | sound on finish |

The window dot always shows its **worst** pane: `blocked > working > idle`. You only
get alerted on a real state change, and never for the pane you're already looking at.

---

## Supported agents

| Agent | Flag | Where it installs |
|-------|------|-------------------|
| opencode | `--with-opencode` | `~/.config/opencode/plugins/` |
| pi | `--with-pi` | `~/.pi/agent/extensions/` |
| Claude Code | `--with-claude` | merges hooks into `~/.claude/settings.json` |
| Codex | `--with-codex` | merges hooks into `~/.codex/hooks.json` |
| *all detected* | `--all` | every agent whose config dir exists |

**Adapters are opt-in.** The installer never touches a tool you didn't ask for. The
Claude/Codex hook merge is append-only and idempotent — it adds one hook without
clobbering anything you already configured.

---

## How it works

Every agent emits a different event dialect. Instead of teaching tmux about each one,
each agent gets a thin **adapter** that normalizes its native events into a single
canonical vocabulary — `working` / `blocked` / `idle` — and calls one core script:

```
opencode ┐
pi       ├──▶  agent-report.sh  ──▶  tmux (per-tab dot · rollup · alert)
claude   │
codex    ┘
```

tmux only ever sees the core — it never knows which agent ran. Add a new agent by
writing one adapter; nothing downstream changes. (This is an anti-corruption layer.)

<details>
<summary>The core pieces</summary>

- **`agent-report.sh`** — the normalization core. Maps a canonical state onto the
  pane, rolls the worst state up to the window, and alerts only on a transition into
  an attention state while the pane is off-screen.
- **`agent-status.sh`** — the self-heal. Clears a stuck `blocked` on every pane of
  the window you're viewing (a window's panes are all on-screen, so a blocked
  background pane gets healed too). No event fires when a prompt is cancelled, so the
  state would otherwise stick forever. It runs both as a silent `status-right`
  heartbeat AND on tmux navigation hooks (`after-select-window`, `after-select-pane`,
  `pane-focus-in`, `client-session-changed`) so it fires the instant you go look —
  even if your theme clobbers `status-right`.
- **`agent-statusline.sh`** — idempotently prepends the heartbeat to `status-right`,
  re-applied on `client-attached` because TPM themes set `status-right`
  asynchronously and would otherwise clobber the prepend.
- **`agents.conf`** — the display layer: per-tab dot, status interval, navigation
  hooks, visual bell. Sourced **last** so it extends your theme's tab format instead
  of overwriting it.

</details>

---

## Configuration

| Env var | Default (macOS / Linux) | Effect |
|---------|-------------------------|--------|
| `AGENT_SOUND_BLOCKED` | `Funk.aiff` / `dialog-warning.oga` | sound when an agent gets blocked |
| `AGENT_SOUND_IDLE` | `Glass.aiff` / `complete.oga` | sound when a busy agent finishes |
| `HERDR_ENV=1` | — | disables every adapter |

Dot colors live in `agents.conf` (kanagawa palette: `#e82424` blocked, `#dca561`
working). Using another theme? Edit the hex values.

---

## Requirements

`tmux` · `jq` · `python3` · `bash`

On Termux:

```sh
./install.sh --all
```

When running on Termux, the installer automatically installs missing
dependencies (`tmux`, `jq`, `python`) before continuing.

Sound is **best-effort and optional**: macOS uses `afplay`; Linux falls back to
`paplay` → `canberra-gtk-play` → `aplay`, whichever exists. No player, no sound —
nothing breaks.

---

## Uninstall

```sh
./uninstall.sh
```

Removes the core, the source line, and the opencode/pi adapter files. Claude/Codex
hooks are stripped **by name** — anything else you configured stays untouched.

---

## License

MIT — see [LICENSE](./LICENSE).
