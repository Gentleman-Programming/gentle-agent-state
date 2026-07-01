#!/usr/bin/env bash
# ghostty-agent-report — native Ghostty backend for the agent-state notifier.
#
# Ghostty has no tmux/Zellij-style pane metadata available to shell hooks, so this
# backend publishes the latest state by changing the terminal title with an OSC
# escape sequence and plays best-effort transition sounds.
#
# usage: ghostty-agent-report.sh <ignored> <working|blocked|idle> [message]
set -uo pipefail

pane="${1:-ghostty}"
state="${2:-}"
msg="${3:-}"
[ -n "$state" ] || exit 0

case "$state" in working | blocked | idle | unknown) ;; *) exit 0 ;; esac

case "$(uname -s)" in
Darwin)
	SOUND_BLOCKED="${AGENT_SOUND_BLOCKED:-/System/Library/Sounds/Funk.aiff}"
	SOUND_IDLE="${AGENT_SOUND_IDLE:-/System/Library/Sounds/Glass.aiff}"
	;;
*)
	SOUND_BLOCKED="${AGENT_SOUND_BLOCKED:-/usr/share/sounds/freedesktop/stereo/dialog-warning.oga}"
	SOUND_IDLE="${AGENT_SOUND_IDLE:-/usr/share/sounds/freedesktop/stereo/complete.oga}"
	;;
esac

play() {
	[ -f "$1" ] || return 0
	if command -v afplay >/dev/null 2>&1; then
		(afplay "$1" >/dev/null 2>&1 &)
	elif command -v paplay >/dev/null 2>&1; then
		(paplay "$1" >/dev/null 2>&1 &)
	elif command -v canberra-gtk-play >/dev/null 2>&1; then
		(canberra-gtk-play -f "$1" >/dev/null 2>&1 &)
	elif command -v aplay >/dev/null 2>&1; then
		(aplay -q "$1" >/dev/null 2>&1 &)
	fi
}

safe_id() { printf '%s' "$1" | tr -c '[:alnum:]_.-' '_'; }

state_dir="${XDG_RUNTIME_DIR:-/tmp}/agent-state-ghostty"
mkdir -p "$state_dir" 2>/dev/null || true

tty_id="$(tty 2>/dev/null || true)"
[ "$tty_id" = "not a tty" ] && tty_id=""
state_key="${AGENT_GHOSTTY_STATE_KEY:-${tty_id:-${pane}_${PPID}}}"
state_file="$state_dir/$(safe_id "$state_key").state"
prev="$(cat "$state_file" 2>/dev/null || true)"
printf '%s' "$state" >"$state_file" 2>/dev/null || true

if [ "$state" != "$prev" ]; then
	case "$state" in
	blocked)
		play "$SOUND_BLOCKED"
		;;
	idle)
		case "$prev" in
		working) play "$SOUND_IDLE" ;;
		esac
		;;
	esac
fi

case "$state" in
blocked) title="agent: blocked${msg:+ — $msg}" ;;
working) title="agent: working" ;;
idle) title="agent: idle" ;;
unknown) title="agent: unknown" ;;
esac

# Keep notification text from injecting nested terminal control sequences.
title="${title//$'\033'/}"
title="${title//$'\a'/}"

emit_title() {
	printf '\033]2;%s\007' "$title"
}

if [ "${AGENT_GHOSTTY_FORCE_STDOUT:-}" = "1" ]; then
	emit_title
	exit 0
fi

if [ -w /dev/tty ] && emit_title 2>/dev/null >/dev/tty; then
	exit 0
fi

emit_title
