#!/usr/bin/env bash
# uninstall.sh — remove the tmux agent-state notifier.
#
# Removes the core scripts, agents.conf, the source line, and the opencode/pi
# adapter files. Claude/Codex hooks are removed by name (jq), leaving any other
# hooks you configured untouched.
set -euo pipefail

say() { printf '%s\n' "$*"; }
HOOK="bash $HOME/.config/tmux/scripts/hook-adapter.sh"

# --- core ---
rm -f "$HOME/.config/tmux/scripts/agent-report.sh" \
      "$HOME/.config/tmux/scripts/agent-status.sh" \
      "$HOME/.config/tmux/scripts/hook-adapter.sh" \
      "$HOME/.config/tmux/agents.conf"
say "🧹 removed core scripts + agents.conf"

# --- source line (from either possible config path) ---
for conf in "$HOME/.config/tmux/tmux.conf" "$HOME/.tmux.conf"; do
  [ -f "$conf" ] || continue
  if grep -qF 'agents.conf' "$conf"; then
    # drop our source line and the comment immediately above it
    tmp="$conf.tmp"
    grep -vF 'agents.conf' "$conf" | grep -v 'tmux agent-state notifier — sourced last' > "$tmp" && mv "$tmp" "$conf"
    say "  ✂️  cleaned source line from $conf"
  fi
done

# --- adapters ---
rm -f "$HOME/.config/opencode/plugins/tmux-agent-state.js"
rm -f "$HOME/.pi/agent/extensions/tmux-agent-state.ts"
say "  🔌 removed opencode + pi adapters (if present)"

# --- claude/codex hooks: drop only OUR command, keep everything else ---
strip_hooks() {
  local file="$1"
  [ -f "$file" ] || return 0
  command -v jq >/dev/null 2>&1 || { say "  ⚠️  jq not found, leaving $file untouched"; return 0; }
  jq --arg cmdprefix "$HOOK" '
    if .hooks then
      .hooks |= with_entries(
        .value |= map(
          .hooks |= map(select((.command // "") | startswith($cmdprefix) | not))
        ) | .value |= map(select((.hooks | length) > 0))
      ) | .hooks |= with_entries(select((.value | length) > 0))
    else . end
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  say "  🪝 stripped our hooks from $file"
}
strip_hooks "$HOME/.claude/settings.json"
strip_hooks "$HOME/.codex/hooks.json"

say ""
say "✅ uninstalled. Restart tmux + your agents to fully clear state."
