#!/usr/bin/env bash
# install.sh — tmux agent-state notifier installer.
#
# Installs the tmux display layer + normalization core, and (opt-in) the per-agent
# adapters. Each adapter is installed ONLY when you ask for it, so this never touches
# the config of a tool you don't use.
#
#   ./install.sh                         core only (tmux display + scripts)
#   ./install.sh --with-opencode         core + opencode adapter
#   ./install.sh --with-pi --with-claude core + pi + claude adapters
#   ./install.sh --all                   core + every adapter whose tool is detected
#
# Adapters: --with-opencode  --with-pi  --with-claude  --with-codex
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMUX_DIR="$HOME/.config/tmux"
SCRIPTS_DIR="$TMUX_DIR/scripts"

want_opencode=0 want_pi=0 want_claude=0 want_codex=0 want_all=0
for arg in "$@"; do
  case "$arg" in
    --with-opencode) want_opencode=1 ;;
    --with-pi)       want_pi=1 ;;
    --with-claude)   want_claude=1 ;;
    --with-codex)    want_codex=1 ;;
    --all)           want_all=1 ;;
    -h|--help)
      sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown flag: $arg (try --help)" >&2; exit 1 ;;
  esac
done

say() { printf '%s\n' "$*"; }

# --- dependency check ---
missing=""
command -v tmux    >/dev/null 2>&1 || missing="$missing tmux"
command -v jq      >/dev/null 2>&1 || missing="$missing jq"
command -v python3 >/dev/null 2>&1 || missing="$missing python3"
if [ -n "$missing" ]; then
  say "❌ missing required tools:$missing"
  say "   install them and re-run. (jq + python3 power the claude/codex hook adapters)"
  exit 1
fi

# --- core: scripts + display layer ---
say "🔧 installing tmux agent-state core..."
mkdir -p "$SCRIPTS_DIR"
cp -f "$SRC/tmux/scripts/"*.sh "$SCRIPTS_DIR/"
chmod +x "$SCRIPTS_DIR/"*.sh
cp -f "$SRC/tmux/agents.conf" "$TMUX_DIR/agents.conf"
say "  ⚙️  scripts + agents.conf installed to $TMUX_DIR"

# --- ensure the tmux config sources agents.conf (idempotent, at end of file) ---
# Prefer ~/.config/tmux/tmux.conf, fall back to ~/.tmux.conf.
TMUX_CONF="$TMUX_DIR/tmux.conf"
[ -f "$TMUX_CONF" ] || { [ -f "$HOME/.tmux.conf" ] && TMUX_CONF="$HOME/.tmux.conf"; }
[ -f "$TMUX_CONF" ] || TMUX_CONF="$TMUX_DIR/tmux.conf"   # create the modern path if neither exists

SOURCE_LINE="if-shell '[ -f ~/.config/tmux/agents.conf ]' 'source-file ~/.config/tmux/agents.conf'"
if [ -f "$TMUX_CONF" ] && grep -qF 'agents.conf' "$TMUX_CONF"; then
  say "  ✅ $TMUX_CONF already sources agents.conf"
else
  mkdir -p "$(dirname "$TMUX_CONF")"
  {
    printf '\n# tmux agent-state notifier — sourced last so the per-tab dot extends the theme\n'
    printf '%s\n' "$SOURCE_LINE"
  } >> "$TMUX_CONF"
  say "  ➕ appended source line to $TMUX_CONF"
fi

# --- adapters (opt-in) ---
install_opencode() {
  local dst="$HOME/.config/opencode/plugins"
  mkdir -p "$dst"
  cp -f "$SRC/adapters/opencode/tmux-agent-state.js" "$dst/"
  say "  🔌 opencode adapter → $dst"
}
install_pi() {
  local dst="$HOME/.pi/agent/extensions"
  mkdir -p "$dst"
  cp -f "$SRC/adapters/pi/tmux-agent-state.ts" "$dst/"
  say "  🔌 pi adapter → $dst"
}

HOOK="bash $HOME/.config/tmux/scripts/hook-adapter.sh"

# merge_hooks <target.json> <Event:matcher> ...
# APPENDS our hook (never replaces arrays), only if not already present — so it
# never clobbers other hooks you have configured.
merge_hooks() {
  local file="$1"; shift
  [ -f "$file" ] || echo '{"hooks":{}}' > "$file"
  local filter='.hooks = (.hooks // {})'
  local pair ev matcher
  for pair in "$@"; do
    ev="${pair%%:*}"; matcher="${pair#*:}"
    filter="$filter | addhook(\"$ev\"; \"$matcher\")"
  done
  jq --arg base "$HOOK" "
    def addhook(\$ev; \$matcher):
      (\$base + \" \" + \$ev) as \$cmd
      | .hooks[\$ev] = ((.hooks[\$ev] // [])
        | if any(.[].hooks[]?; .command == \$cmd) then .
          else . + [{matcher: \$matcher, hooks: [{type: \"command\", command: \$cmd, timeout: 5}]}] end);
    $filter
  " "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

install_claude() {
  local file="$HOME/.claude/settings.json"
  if [ ! -f "$file" ]; then
    say "  ⏭️  claude: $file not found — run Claude once, then re-run with --with-claude"
    return
  fi
  merge_hooks "$file" "UserPromptSubmit:" "PreToolUse:*" "Notification:" "Stop:"
  say "  🪝 claude hooks merged → $file"
}
install_codex() {
  local file="$HOME/.codex/hooks.json"
  if [ ! -f "$file" ]; then
    say "  ⏭️  codex: $file not found — run Codex once, then re-run with --with-codex"
    return
  fi
  merge_hooks "$file" "UserPromptSubmit:" "PreToolUse:*" "Notification:" "Stop:" "TurnComplete:"
  say "  🪝 codex hooks merged → $file (approve the new hooks on next codex start)"
}

# --all = install every adapter whose tool is detected on disk
if [ "$want_all" = 1 ]; then
  [ -d "$HOME/.config/opencode" ] && want_opencode=1
  [ -d "$HOME/.pi" ]              && want_pi=1
  [ -d "$HOME/.claude" ]          && want_claude=1
  [ -d "$HOME/.codex" ]           && want_codex=1
fi

[ "$want_opencode" = 1 ] && install_opencode
[ "$want_pi" = 1 ]       && install_pi
[ "$want_claude" = 1 ]   && install_claude
[ "$want_codex" = 1 ]    && install_codex

if [ "$want_opencode$want_pi$want_claude$want_codex$want_all" = "00000" ]; then
  say ""
  say "ℹ️  core installed, no adapters. Add the agents you use:"
  say "    ./install.sh --with-opencode --with-pi --with-claude --with-codex"
  say "    ./install.sh --all      # auto-detect installed tools"
fi

say ""
say "🎉 done. Open a fresh tmux (or: tmux source-file $TMUX_CONF) and restart your agents."
