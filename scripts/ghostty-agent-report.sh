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
title_file="$state_dir/$(safe_id "$state_key").title"
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
blocked) marker="x" ;;
working) marker="o" ;;
idle) marker="" ;;
unknown) marker="?" ;;
esac

clean_title_name() {
	printf '%s' "$1" | sed -E 's/[[:space:]]+(o|x|\?)$//'
}

query_title() {
	if [ -n "${AGENT_GHOSTTY_CURRENT_TITLE:-}" ]; then
		printf '%s' "$AGENT_GHOSTTY_CURRENT_TITLE"
		return 0
	fi
	[ -r /dev/tty ] && [ -w /dev/tty ] || return 0
	# XTerm window-title query: CSI 21 t. Supporting terminals respond with
	# OSC l <title> ST. Ghostty support can vary, so this is best-effort only.
	{ exec 9<>/dev/tty; } 2>/dev/null || return 0
	old_stty="$(stty -g <&9 2>/dev/null || true)"
	[ -n "$old_stty" ] && stty raw -echo min 0 time 2 <&9 2>/dev/null || true
	printf '\033[21t' >&9 2>/dev/null || true
	IFS= read -r -t 0.2 response <&9 2>/dev/null || response=""
	[ -n "$old_stty" ] && stty "$old_stty" <&9 2>/dev/null || true
	exec 9>&- 9<&- 2>/dev/null || true
	case "$response" in
	$'\033]l'*)
		response="${response#$'\033]l'}"
		response="${response%$'\033\\'}"
		printf '%s' "$response"
		;;
	esac
}

shell_title() {
	case "${SHELL:-}" in
	*fish)
		command -v fish >/dev/null 2>&1 || return 0
		fish -lc 'fish_title' 2>/dev/null | head -n 1
		;;
	*)
		return 0
		;;
	esac
}

remember_title() {
	base_title="${AGENT_GHOSTTY_TITLE_BASE:-}"
	if [ -z "$base_title" ] && [ -f "$title_file" ]; then
		base_title="$(cat "$title_file" 2>/dev/null || true)"
	fi
	if [ -z "$base_title" ]; then
		base_title="$(query_title)"
		# Only remove a suffix when recovering from our own prior busy state without
		# a cached original title. Fresh titles like "release x" must be preserved.
		case "$prev" in
		working | blocked) base_title="$(clean_title_name "$base_title")" ;;
		esac
	fi
	if [ -z "$base_title" ]; then
		base_title="$(shell_title)"
	fi
	if [ -n "$base_title" ]; then
		printf '%s' "$base_title" >"$title_file" 2>/dev/null || true
	fi
	printf '%s' "$base_title"
}

base_title="$(remember_title)"
if [ -n "$base_title" ] && [ -n "$marker" ]; then
	title="$base_title $marker"
elif [ -n "$base_title" ]; then
	title="$base_title"
else
	title="$marker"
fi

case "$state" in
idle | unknown) rm -f "$title_file" 2>/dev/null || true ;;
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
