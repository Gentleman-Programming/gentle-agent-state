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

# Zellij accepts bare numeric pane ids, but plugin and terminal ids can collide
# (eg. terminal_2 and plugin_2). Agent panes are terminal panes, so target the
# explicit terminal namespace for native rename/restore actions.
pane_action_id="$pane"
case "$pane" in
terminal_* | plugin_*) ;;
*[!0-9]*) ;;
*) pane_action_id="terminal_$pane" ;;
esac

session="${ZELLIJ_SESSION_NAME:-default}"
state_dir="${XDG_RUNTIME_DIR:-/tmp}/agent-state-zellij"
mkdir -p "$state_dir" 2>/dev/null || true

# Keep user-managed tab names stable by default. Pane titles still show the
# exact agent state; tab-title rollup remains available as an explicit opt-in.
rename_tabs="${AGENT_ZELLIJ_RENAME_TAB:-0}"

safe_id() { printf '%s' "$1" | tr -c '[:alnum:]_.-' '_'; }

pane_key="$(safe_id "$session")_pane_$(safe_id "$pane")"
state_file="$state_dir/${pane_key}.state"
pane_tab_file="$state_dir/${pane_key}.tab"
prev="$(cat "$state_file" 2>/dev/null || true)"
printf '%s' "$state" >"$state_file" 2>/dev/null || true

# Include tab and state fields: tab_id/tab_name are needed for rollup, and
# focused state is needed to avoid beeping when the user is already on the pane.
pane_info_json="$(zellij action list-panes --json --tab --state 2>/dev/null \
	|| zellij action list-panes --json --tab --all 2>/dev/null \
	|| zellij action list-panes --json --tab 2>/dev/null \
	|| zellij action list-panes --json 2>/dev/null \
	|| true)"
current_tab_json="$(zellij action current-tab-info --json 2>/dev/null || true)"

pane_filter='
  select(
    (
      ((.id | tostring) == $pane or ("terminal_" + (.id | tostring)) == $pane)
      and ((.is_plugin // false) | not)
    )
    or (
      ("plugin_" + (.id | tostring)) == $pane
      and (.is_plugin // false)
    )
  )
'

tab_id=""
tab_name=""
pane_title=""
focused="0"
if [ -n "$pane_info_json" ]; then
	tab_id="$(printf '%s' "$pane_info_json" | jq -r --arg pane "$pane" "
    .[] | $pane_filter | .tab_id // empty
  " 2>/dev/null | head -n 1)"
	tab_name="$(printf '%s' "$pane_info_json" | jq -r --arg pane "$pane" "
    .[] | $pane_filter | .tab_name // empty
  " 2>/dev/null | head -n 1)"
	pane_title="$(printf '%s' "$pane_info_json" | jq -r --arg pane "$pane" "
    .[] | $pane_filter | .title // empty
  " 2>/dev/null | head -n 1)"
	focused="$(printf '%s' "$pane_info_json" | jq -r --arg pane "$pane" "
    .[] | $pane_filter
    | if (.is_focused // .focused // .active // false) then \"1\" else \"0\" end
  " 2>/dev/null | head -n 1)"
fi

# If Pi exits and the pane disappears before the final idle report can resolve
# its live pane metadata, fall back to the last tab id we saw for this pane.
if [ -n "$tab_id" ]; then
	printf '%s' "$tab_id" >"$pane_tab_file" 2>/dev/null || true
else
	tab_id="$(cat "$pane_tab_file" 2>/dev/null || true)"
fi

if [ -z "$tab_name" ] && [ -n "$tab_id" ] && [ -n "$pane_info_json" ]; then
	tab_name="$(printf '%s' "$pane_info_json" | jq -r --arg tab_id "$tab_id" '
    .[] | select((.tab_id | tostring) == $tab_id) | .tab_name // empty
  ' 2>/dev/null | head -n 1)"
fi

current_tab_id=""
if [ -n "$current_tab_json" ]; then
	current_tab_id="$(printf '%s' "$current_tab_json" | jq -r '.id // .tab_id // empty' 2>/dev/null | head -n 1)"
fi

# Visible means the user is on the same tab and exact focused pane. If Zellij
# omits either field, stay conservative and allow the notification.
visible="0"
if [ -n "$tab_id" ] && [ -n "$current_tab_id" ] && [ "$tab_id" = "$current_tab_id" ] && [ "$focused" = "1" ]; then
	visible="1"
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

notify_sound() {
	[ "$visible" != "1" ] || return 0
	play "$1"
}

rename_pane() {
	[ "$pane_title" = "$1" ] && return 0
	zellij action rename-pane --pane-id "$pane_action_id" "$1" >/dev/null 2>&1 || true
}

restore_pane() {
	case "$pane_title" in
	"o" | "x" | "●" | "- working" | "- blocked" | "● working" | "● blocked" | "● agent working" | "● agent blocked" | "o working" | "x blocked" | "o agent working" | "x agent blocked")
		zellij action undo-rename-pane --pane-id "$pane_action_id" >/dev/null 2>&1 || true
		;;
	esac
}

tab_original_file=""
if [ -n "$tab_id" ]; then
	tab_original_file="$state_dir/$(safe_id "$session")_tab_$(safe_id "$tab_id").name"
fi

clean_tab_name() {
	printf '%s' "$1" | sed -E 's/(^[ox●]$|[[:space:]]+(o|x|●|- (agent )?(working|blocked)|● (agent )?(working|blocked)|o (agent )?working|x (agent )?blocked))$//'
}

remember_tab_name() {
	[ -n "$tab_original_file" ] || return 0
	current="$(clean_tab_name "$tab_name")"
	# If the user manually renamed the tab while the agent suffix was active,
	# prefer the current visible base name over the stale cached one.
	if [ -n "$current" ] && { [ ! -f "$tab_original_file" ] || [ "$tab_name" = "$current" ]; }; then
		printf '%s' "$current" >"$tab_original_file" 2>/dev/null || true
	fi
}

rename_tab() {
	[ "$rename_tabs" = "1" ] || return 0
	[ -n "$tab_id" ] || return 0
	remember_tab_name
	original=""
	[ -n "$tab_original_file" ] && original="$(cat "$tab_original_file" 2>/dev/null || true)"
	if [ -n "$original" ]; then
		desired="$original $1"
	else
		desired="$1"
	fi
	[ "$tab_name" = "$desired" ] && return 0
	zellij action rename-tab --tab-id "$tab_id" "$desired" >/dev/null 2>&1 || true
}

restore_tab() {
	[ -n "$tab_id" ] || return 0
	original=""
	if [ -n "$tab_original_file" ] && [ -f "$tab_original_file" ]; then
		original="$(cat "$tab_original_file" 2>/dev/null || true)"
	fi
	if [ -z "$original" ]; then
		original="$(clean_tab_name "$tab_name")"
	fi
	if [ "$rename_tabs" != "1" ] && [ "$tab_name" = "$original" ]; then
		rm -f "$tab_original_file" 2>/dev/null || true
		return 0
	fi
	if [ -n "$original" ]; then
		zellij action rename-tab --tab-id "$tab_id" "$original" >/dev/null 2>&1 || true
	else
		zellij action undo-rename-tab --tab-id "$tab_id" >/dev/null 2>&1 || true
	fi
	rm -f "$tab_original_file" 2>/dev/null || true
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
		if [ -z "$pane_state" ]; then
			pane_state_file="$state_dir/$(safe_id "$session")_pane_$(safe_id "terminal_$pane_id").state"
			pane_state="$(cat "$pane_state_file" 2>/dev/null || true)"
		fi
		case "$pane_state" in
		blocked)
			worst="blocked"
			break
			;;
		working) [ "$worst" = "idle" ] && worst="working" ;;
		esac
	done < <(printf '%s' "$pane_info_json" | jq -r --arg tab_id "$tab_id" '
    .[]
    | select((.tab_id | tostring) == $tab_id)
    | select((.is_plugin // false) | not)
    | .id
  ' 2>/dev/null)

	printf '%s' "$worst"
}

apply_tab_rollup() {
	rollup="$(rollup_tab_state)"
	rollup_file=""
	if [ -n "$tab_id" ]; then
		rollup_file="$state_dir/$(safe_id "$session")_tab_$(safe_id "$tab_id").state"
		printf '%s' "$rollup" >"$rollup_file" 2>/dev/null || true
	fi

	case "$rollup" in
	blocked) rename_tab "x" ;;
	working) rename_tab "o" ;;
	idle | unknown | *) restore_tab ;;
	esac
}

case "$state" in
blocked)
	rename_pane "x"
	apply_tab_rollup
	if [ "$state" != "$prev" ]; then
		notify_sound "$SOUND_BLOCKED"
	fi
	;;
working)
	rename_pane "o"
	apply_tab_rollup
	;;
idle)
	restore_pane
	# Remove this pane from the rollup before recomputing the tab. This keeps a
	# final idle/cleanup report from leaving its own stale busy state behind.
	rm -f "$state_file" 2>/dev/null || true
	apply_tab_rollup
	rm -f "$pane_tab_file" 2>/dev/null || true
	case "$prev" in working | blocked) notify_sound "$SOUND_IDLE" ;; esac
	true
	;;
unknown)
	restore_pane
	rm -f "$state_file" 2>/dev/null || true
	apply_tab_rollup
	rm -f "$pane_tab_file" 2>/dev/null || true
	;;
esac
