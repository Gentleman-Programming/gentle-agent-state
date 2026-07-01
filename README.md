# gentle-agent-state

**See when an AI agent needs you without hunting through panes.**

gentle-agent-state connects AI coding agents to your terminal session. Agents
emit lifecycle events, this project normalizes them into `working`, `blocked`, and
`idle`, then shows the state in **tmux**, **Zellij**, or native **Ghostty**.

- **tmux:** colored state markers in the window/tab bar, rolled up from all panes.
- **Zellij:** the tab title can roll up agent state; the exact agent pane title changes too.
- **Ghostty:** the native window/tab title shows the latest agent state and plays transition sounds.
- **Agents:** opencode, pi, Claude Code, and Codex.

```text
  1 api o      2 claude x      3 notes
  (orange)    (red, beeps)    (idle)
```

---

## Quick path

```sh
git clone https://github.com/Gentleman-Programming/gentle-agent-state.git
cd gentle-agent-state
./install.sh --all
```

Then restart your agents inside tmux, Zellij, or Ghostty.

For tmux, either open a fresh tmux session or reload your config:

```sh
tmux source-file ~/.config/tmux/tmux.conf
```

Want only specific agents?

```sh
./install.sh --with-opencode --with-pi
./install.sh --with-claude --with-codex
```

---

## What you get

| State | Meaning | tmux display | Zellij display | Ghostty display | Alert |
|-------|---------|--------------|----------------|-----------------|-------|
| `working` | Agent is running | `o` in orange | pane title: `o` | title: `agent: working` | none |
| `blocked` | Agent is waiting for you | `x` in red | pane title: `x` | title: `agent: blocked` | sound + flash/message in tmux/Zellij, sound in Ghostty |
| `idle` | Agent finished or is not running | no marker | pane title restored | title: `agent: idle` | sound after busy state |

### tmux behavior

The window state marker shows the **worst state across panes**:

```text
blocked > working > idle
```

So if any pane in a tmux window is blocked, that window shows `x` in red.

### Zellij behavior

Zellij does not expose tmux-style window user options, so the backend uses native
pane renaming actions. By default it does **not** rename tabs, preserving
user-managed tab names exactly; the exact agent pane title shows its own state.

If you prefer tab-title rollup, opt in with `AGENT_ZELLIJ_RENAME_TAB=1`. In that
mode the tab title appends the worst state across panes in that tab, and the
backend best-effort restores the original tab name when the tab returns to idle.

### Ghostty behavior

Native Ghostty support uses `TERM_PROGRAM=ghostty`, updates the terminal title
with OSC escape sequences, and plays the same best-effort transition sounds as
other backends: blocked sound when the state becomes `blocked`, and idle sound
when `working` returns to `idle`. A direct `blocked` → `idle` transition stays
quiet to avoid double-playing blocked and success sounds for prompts. Ghostty does not expose tmux/Zellij-style pane rollup
to these shell hooks, so this backend intentionally shows only the latest state
for the current terminal session. If you run tmux or Zellij inside Ghostty, the
tmux/Zellij backend still takes precedence.

---

## Supported agents

| Agent | Install flag | Install target |
|-------|--------------|----------------|
| opencode | `--with-opencode` | `~/.config/opencode/plugins/gentle-agent-state.js` |
| pi | `--with-pi` | `~/.pi/agent/extensions/gentle-agent-state.ts` |
| Claude Code | `--with-claude` | merges hooks into `~/.claude/settings.json` |
| Codex | `--with-codex` | merges hooks into `~/.codex/hooks.json` |
| all detected | `--all` | every detected agent config directory |

Adapters are **opt-in**. The installer only touches agents you request, except
`--all`, which selects agents whose config directories already exist.

Claude/Codex hook merging is append-only and idempotent. Existing hooks are kept.
Legacy `tmux-agent-state` hook commands are migrated to the neutral
`gentle-agent-state` core path.

---

## Requirements

Required:

- `bash`
- `jq`
- `python3`
- at least one display backend: `tmux`, `zellij`, or Ghostty

Optional sound players:

- macOS: `afplay`
- Linux/BSD: `paplay`, `canberra-gtk-play`, or `aplay`

No sound player? Nothing breaks; alerts just become visual/state-only.

---

## Configuration

| Env var | Default | Effect |
|---------|---------|--------|
| `AGENT_SOUND_BLOCKED` | macOS `Funk.aiff`, Linux `dialog-warning.oga` | sound when an agent becomes blocked |
| `AGENT_SOUND_IDLE` | macOS `Glass.aiff`, Linux `complete.oga` | sound when a busy agent finishes |
| `HERDR_ENV=1` | unset | disables every adapter so Herdr can own integration |

### tmux colors

tmux state marker colors live in `tmux/agents.conf`:

| State | Color |
|-------|-------|
| blocked | `#e82424` |
| working | `#dca561` |

Edit those values if your theme needs different colors.

---

## How it works

Every agent has its own event dialect. gentle-agent-state keeps that complexity at
the edge with thin adapters:

```text
opencode ┐
pi       ├──▶  agent-report.sh  ──▶  tmux backend
Claude   │                       ├─▶  Zellij backend
Codex    ┘                       └─▶  Ghostty title + sound backend
```

The core vocabulary is deliberately small:

| Canonical state | Example source event |
|-----------------|----------------------|
| `working` | prompt submitted, tool started, session active |
| `blocked` | permission request, user question, approval needed |
| `idle` | stop, turn complete, session idle |

This is an anti-corruption layer: adding a new agent should require one adapter,
not changes to every multiplexer backend.

### Installed core files

| Path | Purpose |
|------|---------|
| `~/.config/agent-state/scripts/agent-report.sh` | neutral dispatcher |
| `~/.config/agent-state/scripts/tmux-agent-report.sh` | tmux backend |
| `~/.config/agent-state/scripts/zellij-agent-report.sh` | Zellij backend |
| `~/.config/agent-state/scripts/ghostty-agent-report.sh` | Ghostty title + sound backend |
| `~/.config/agent-state/scripts/hook-adapter.sh` | Claude/Codex hook adapter |

### tmux-specific files

| Path | Purpose |
|------|---------|
| `~/.config/tmux/agents.conf` | tab state markers, hooks, visual bell |
| `~/.config/tmux/scripts/agent-status.sh` | clears stale blocked states when panes become visible |
| `~/.config/tmux/scripts/agent-statusline.sh` | keeps the self-heal heartbeat in `status-right` |

---

## Troubleshooting

### I installed it, but nothing changes

Check that you restarted the agent process after installing the adapter. Most
agents load plugins/extensions only on startup.

### tmux state markers do not appear

Reload tmux config:

```sh
tmux source-file ~/.config/tmux/tmux.conf
```

Then confirm your config sources the generated file:

```sh
grep agents.conf ~/.config/tmux/tmux.conf ~/.tmux.conf 2>/dev/null
```

### Zellij tab or pane title does not change

Confirm the agent is running inside Zellij and has a pane id:

```sh
echo "$ZELLIJ_PANE_ID"
zellij action rename-pane --pane-id "$ZELLIJ_PANE_ID" "test-pane"
zellij action undo-rename-pane --pane-id "$ZELLIJ_PANE_ID"
zellij action current-tab-info
zellij action rename-tab "test-tab"
zellij action undo-rename-tab
```

### Ghostty title does not change

Confirm the agent is running directly inside Ghostty:

```sh
echo "$TERM_PROGRAM"
printf '\033]2;ghostty-title-test\007'
```

If you are running tmux or Zellij inside Ghostty, troubleshoot that backend
instead; tmux/Zellij take precedence over the native Ghostty title backend.

### Claude or Codex hooks do not fire

Re-run the installer for that agent and inspect the hook file:

```sh
./install.sh --with-claude
jq '.hooks' ~/.claude/settings.json

./install.sh --with-codex
jq '.hooks' ~/.codex/hooks.json
```

### I use Herdr

Set `HERDR_ENV=1`. All adapters exit early and let Herdr own the integration.

---

## Uninstall

```sh
./uninstall.sh
```

This removes:

- the neutral core scripts, including tmux/Zellij/Ghostty backends;
- tmux `agents.conf` and generated tmux scripts;
- the tmux source line from `~/.config/tmux/tmux.conf` or `~/.tmux.conf`;
- opencode/pi adapter files;
- Claude/Codex hooks added by this project.

Other hooks and user configuration are preserved.

---

## Development notes

Run quick checks before opening a PR:

```sh
bash -n install.sh uninstall.sh scripts/*.sh tmux/scripts/*.sh
node --check adapters/opencode/gentle-agent-state.js
bash tests/ghostty-contract.sh
```

A useful smoke test is installing into a temporary home:

```sh
tmp="$(mktemp -d)"
HOME="$tmp" ./install.sh
HOME="$tmp" ./uninstall.sh
```

---

## License

MIT — see [LICENSE](./LICENSE).
