#!/usr/bin/env bash
# agent-report — normalization core (anti-corruption layer).
# Every agent adapter (opencode, pi, claude, codex, ...) calls THIS and nothing else.
# It maps a canonical state onto tmux (pane + window rollup) and fires the push alert.
#
# usage: agent-report.sh <pane_id> <working|blocked|idle> [message]
#   pane_id   tmux pane id the agent runs in (adapters pass $TMUX_PANE)
#   state     canonical state; anything else is ignored
#   message   optional human label (e.g. permission prompt text)
set -uo pipefail

pane="${1:-}"
state="${2:-}"
msg="${3:-}"
[ -n "$pane" ] && [ -n "$state" ] || exit 0

# --- config: sounds per transition (override via env) ---
# Defaults resolve per-OS; override AGENT_SOUND_BLOCKED / AGENT_SOUND_IDLE to any
# file your audio player can read.
case "$(uname -s)" in
  Darwin)
    SOUND_BLOCKED="${AGENT_SOUND_BLOCKED:-/System/Library/Sounds/Funk.aiff}"
    SOUND_IDLE="${AGENT_SOUND_IDLE:-/System/Library/Sounds/Glass.aiff}"
    ;;
  *)
    # Linux/BSD: freedesktop sound theme is the common denominator. If your distro
    # ships sounds elsewhere, set the env vars above.
    SOUND_BLOCKED="${AGENT_SOUND_BLOCKED:-/usr/share/sounds/freedesktop/stereo/dialog-warning.oga}"
    SOUND_IDLE="${AGENT_SOUND_IDLE:-/usr/share/sounds/freedesktop/stereo/complete.oga}"
    ;;
esac

case "$state" in working|blocked|idle|unknown) ;; *) exit 0 ;; esac
command -v tmux >/dev/null 2>&1 || exit 0

# Cross-platform, best-effort, non-blocking sound. Tries the macOS player first,
# then the common Linux ones. Silent if none exist — sound is never required.
play() {
  [ -f "$1" ] || return 0
  if command -v afplay >/dev/null 2>&1; then (afplay "$1" >/dev/null 2>&1 &)
  elif command -v paplay >/dev/null 2>&1; then (paplay "$1" >/dev/null 2>&1 &)
  elif command -v canberra-gtk-play >/dev/null 2>&1; then (canberra-gtk-play -f "$1" >/dev/null 2>&1 &)
  elif command -v aplay >/dev/null 2>&1; then (aplay -q "$1" >/dev/null 2>&1 &)
  fi
}

# previous pane state, for transition detection (only alert on real changes)
prev="$(tmux show -p -t "$pane" -v @agent_state 2>/dev/null || true)"

# pane-level state (auto-cleaned when the pane dies)
tmux set -p -t "$pane" @agent_state "$state" 2>/dev/null || exit 0
tmux set -p -t "$pane" @agent_msg "$msg" 2>/dev/null || true

# window rollup: worst state across the window's panes (blocked > working > idle)
win="$(tmux display -p -t "$pane" '#{window_id}' 2>/dev/null || true)"
if [ -n "$win" ]; then
  worst=idle
  while read -r s; do
    case "$s" in
      blocked) worst=blocked; break ;;
      working) [ "$worst" = idle ] && worst=working ;;
    esac
  done < <(tmux list-panes -t "$win" -F '#{@agent_state}' 2>/dev/null)
  tmux set -w -t "$win" @win_agent_state "$worst" 2>/dev/null || true
fi

# Is this pane on-screen for an attached client RIGHT NOW? (active pane + active
# window + session attached). If so, you're already looking at it — set the state
# but DON'T nag with sound/popup. Notifications are for agents you're NOT watching.
visible="$(tmux display-message -p -t "$pane" '#{&&:#{pane_active},#{&&:#{window_active},#{session_attached}}}' 2>/dev/null || echo 0)"

# push: alert only on transition INTO an attention state, and only when unattended
if [ "$state" != "$prev" ] && [ "$visible" != "1" ]; then
  case "$state" in
    blocked)
      play "$SOUND_BLOCKED"
      tmux display-message -t "$pane" "#[fg=red,bold]agent needs you#[default] ${msg:-blocked}" 2>/dev/null || true
      ;;
    idle)
      # only "done" beep if it was actually busy before — not on session startup
      case "$prev" in
        working|blocked)
          play "$SOUND_IDLE"
          tmux display-message -t "$pane" "#[fg=green,bold]agent done#[default]" 2>/dev/null || true
          ;;
      esac
      ;;
  esac
fi
