#!/usr/bin/env bash
# zellij-agent-report — Zellij backend for the agent-state notifier.
#
# Zellij does not expose tmux-style window user options. We use the native names
# users already see: pane titles for the exact agent pane and tab titles for the
# tab-level rollup.
#
# usage: zellij-agent-report.sh <pane_id> <working|blocked|idle> [message]
set -uo pipefail

pane="${1:-${ZELLIJ_PANE_ID:-}}"
state="${2:-}"
[ -n "$pane" ] && [ -n "$state" ] || exit 0

case "$state" in working | blocked | idle | unknown) ;; *) exit 0 ;; esac
command -v zellij >/dev/null 2>&1 || exit 0

session="${ZELLIJ_SESSION_NAME:-default}"
state_dir="${XDG_RUNTIME_DIR:-/tmp}/agent-state-zellij"
mkdir -p "$state_dir" 2>/dev/null || true

safe_id() { printf '%s' "$1" | tr -c '[:alnum:]_.-' '_'; }
state_file="$state_dir/$(safe_id "$session")_pane_$(safe_id "$pane").state"
prev="$(cat "$state_file" 2>/dev/null || true)"
printf '%s' "$state" >"$state_file" 2>/dev/null || true

pane_info_json="$(zellij action list-panes --json --tab 2>/dev/null || zellij action list-panes --json 2>/dev/null || true)"
tab_id=""
tab_name=""
if [ -n "$pane_info_json" ]; then
	tab_id="$(printf '%s' "$pane_info_json" | jq -r --arg pane "$pane" '
    .[]
    | select((.id | tostring) == $pane or ("terminal_" + (.id | tostring)) == $pane or ("plugin_" + (.id | tostring)) == $pane)
    | .tab_id // empty
  ' 2>/dev/null | head -n 1)"
	tab_name="$(printf '%s' "$pane_info_json" | jq -r --arg pane "$pane" '
    .[]
    | select((.id | tostring) == $pane or ("terminal_" + (.id | tostring)) == $pane or ("plugin_" + (.id | tostring)) == $pane)
    | .tab_name // empty
  ' 2>/dev/null | head -n 1)"
fi

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

rename_pane() {
	zellij action rename-pane --pane-id "$pane" "$1" >/dev/null 2>&1 || true
}

restore_pane() {
	zellij action undo-rename-pane --pane-id "$pane" >/dev/null 2>&1 || true
}

tab_original_file=""
if [ -n "$tab_id" ]; then
	tab_original_file="$state_dir/$(safe_id "$session")_tab_$(safe_id "$tab_id").name"
fi

clean_tab_name() {
	printf '%s' "$1" | sed -E 's/[[:space:]]*● agent (working|blocked)$//'
}

remember_tab_name() {
	[ -n "$tab_original_file" ] || return 0
	[ -f "$tab_original_file" ] && return 0
	original="$(clean_tab_name "$tab_name")"
	printf '%s' "$original" >"$tab_original_file" 2>/dev/null || true
}

rename_tab() {
	[ -n "$tab_id" ] || return 0
	remember_tab_name
	original=""
	[ -n "$tab_original_file" ] && original="$(cat "$tab_original_file" 2>/dev/null || true)"
	if [ -n "$original" ]; then
		zellij action rename-tab --tab-id "$tab_id" "$original $1" >/dev/null 2>&1 || true
	else
		zellij action rename-tab --tab-id "$tab_id" "$1" >/dev/null 2>&1 || true
	fi
}

restore_tab() {
	[ -n "$tab_id" ] || return 0
	if [ -n "$tab_original_file" ] && [ -f "$tab_original_file" ]; then
		original="$(cat "$tab_original_file" 2>/dev/null || true)"
		if [ -n "$original" ]; then
			zellij action rename-tab --tab-id "$tab_id" "$original" >/dev/null 2>&1 || true
		else
			zellij action undo-rename-tab --tab-id "$tab_id" >/dev/null 2>&1 || true
		fi
		rm -f "$tab_original_file" 2>/dev/null || true
	else
		zellij action undo-rename-tab --tab-id "$tab_id" >/dev/null 2>&1 || true
	fi
}

rollup_tab_state() {
	[ -n "$tab_id" ] && [ -n "$pane_info_json" ] || {
		printf '%s' "$state"
		return
	}

	worst="idle"
	while IFS= read -r pane_id; do
		[ -n "$pane_id" ] || continue
		pane_state_file="$state_dir/$(safe_id "$session")_pane_$(safe_id "$pane_id").state"
		pane_state="$(cat "$pane_state_file" 2>/dev/null || true)"
		case "$pane_state" in
		blocked)
			worst="blocked"
			break
			;;
		working) [ "$worst" = "idle" ] && worst="working" ;;
		esac
	done < <(printf '%s' "$pane_info_json" | jq -r --arg tab_id "$tab_id" '
    .[] | select((.tab_id | tostring) == $tab_id) | .id
  ' 2>/dev/null)

	printf '%s' "$worst"
}

apply_tab_rollup() {
	rollup="$(rollup_tab_state)"
	case "$rollup" in
	blocked) rename_tab "● agent blocked" ;;
	working) rename_tab "● agent working" ;;
	idle | unknown | *) restore_tab ;;
	esac
}

case "$state" in
blocked)
	rename_pane "● agent blocked"
	apply_tab_rollup
	[ "$state" != "$prev" ] && play "$SOUND_BLOCKED"
	;;
working)
	rename_pane "● agent working"
	apply_tab_rollup
	;;
idle)
	restore_pane
	apply_tab_rollup
	case "$prev" in working | blocked) play "$SOUND_IDLE" ;; esac
	;;
unknown)
	restore_pane
	apply_tab_rollup
	;;
esac
