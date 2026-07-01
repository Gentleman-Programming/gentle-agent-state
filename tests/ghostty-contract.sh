#!/usr/bin/env bash
# Contract tests for native Ghostty support.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  expected="$1"
  actual="$2"
  label="$3"
  [ "$actual" = "$expected" ] || fail "$label: expected $(printf %q "$expected"), got $(printf %q "$actual")"
  printf 'ok - %s\n' "$label"
}

wait_for_log() {
  file="$1"
  expected="$2"
  label="$3"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if grep -qx "$expected" "$file" 2>/dev/null; then
      printf 'ok - %s\n' "$label"
      return 0
    fi
    sleep 0.1
  done
  fail "$label: expected log line $(printf %q "$expected")"
}

printf '1..21\n'

# Keep shell syntax coverage deterministic and dependency-free.
bash -n install.sh uninstall.sh scripts/*.sh tmux/scripts/*.sh tests/*.sh
printf 'ok - shell syntax\n'

osc_blocked=$'\033]2;x\007'
osc_working=$'\033]2;o\007'
osc_idle=$'\033]2;\007'
osc_base_blocked=$'\033]2;project x\007'
osc_base_idle=$'\033]2;project\007'
osc_existing_working=$'\033]2;existing-tab o\007'
osc_existing_blocked=$'\033]2;existing-tab x\007'
osc_literal_x_working=$'\033]2;release x o\007'
osc_fish_working=$'\033]2;fish-tab o\007'

early_runtime="$(mktemp -d)"
ghostty_env=(env -i HOME="$HOME" PATH="$PATH" SHELL=/bin/sh TERM_PROGRAM=ghostty AGENT_GHOSTTY_FORCE_STDOUT=1 XDG_RUNTIME_DIR="$early_runtime")

actual="$(${ghostty_env[@]} bash scripts/agent-report.sh ghostty blocked)"
assert_eq "$osc_blocked" "$actual" "Ghostty dispatcher emits blocked title"

actual="$(${ghostty_env[@]} bash scripts/agent-report.sh ghostty idle)"
assert_eq "$osc_idle" "$actual" "Ghostty dispatcher emits idle title"

actual="$(env -i HOME="$HOME" PATH="$PATH" TERM_PROGRAM=ghostty AGENT_GHOSTTY_FORCE_STDOUT=1 AGENT_GHOSTTY_TITLE_BASE=project bash scripts/agent-report.sh ghostty blocked)"
assert_eq "$osc_base_blocked" "$actual" "Ghostty appends blocked marker to configured title"

actual="$(env -i HOME="$HOME" PATH="$PATH" TERM_PROGRAM=ghostty AGENT_GHOSTTY_FORCE_STDOUT=1 AGENT_GHOSTTY_TITLE_BASE=project bash scripts/agent-report.sh ghostty idle)"
assert_eq "$osc_base_idle" "$actual" "Ghostty idle restores configured title"

existing_runtime="$(mktemp -d)"
actual="$(env -i HOME="$HOME" PATH="$PATH" TERM_PROGRAM=ghostty AGENT_GHOSTTY_FORCE_STDOUT=1 XDG_RUNTIME_DIR="$existing_runtime" AGENT_GHOSTTY_STATE_KEY=existing AGENT_GHOSTTY_CURRENT_TITLE=existing-tab bash scripts/agent-report.sh ghostty working)"
assert_eq "$osc_existing_working" "$actual" "Ghostty appends working marker to existing title"

actual="$(env -i HOME="$HOME" PATH="$PATH" TERM_PROGRAM=ghostty AGENT_GHOSTTY_FORCE_STDOUT=1 XDG_RUNTIME_DIR="$existing_runtime" AGENT_GHOSTTY_STATE_KEY=existing AGENT_GHOSTTY_CURRENT_TITLE="existing-tab o" bash scripts/agent-report.sh ghostty blocked)"
assert_eq "$osc_existing_blocked" "$actual" "Ghostty swaps existing title marker without accumulating"
rm -rf "$existing_runtime"

literal_runtime="$(mktemp -d)"
actual="$(env -i HOME="$HOME" PATH="$PATH" TERM_PROGRAM=ghostty AGENT_GHOSTTY_FORCE_STDOUT=1 XDG_RUNTIME_DIR="$literal_runtime" AGENT_GHOSTTY_STATE_KEY=literal AGENT_GHOSTTY_CURRENT_TITLE="release x" bash scripts/agent-report.sh ghostty working)"
assert_eq "$osc_literal_x_working" "$actual" "Ghostty preserves fresh titles ending in marker text"
rm -rf "$literal_runtime"

fish_runtime="$(mktemp -d)"
fish_bin="$fish_runtime/fish"
cat > "$fish_bin" <<'FISH'
#!/usr/bin/env bash
printf 'fish-tab\n'
FISH
chmod +x "$fish_bin"
actual="$(env -i HOME="$HOME" PATH="$fish_runtime:$PATH" SHELL=/usr/bin/fish TERM_PROGRAM=ghostty AGENT_GHOSTTY_FORCE_STDOUT=1 XDG_RUNTIME_DIR="$fish_runtime" AGENT_GHOSTTY_STATE_KEY=fish bash scripts/agent-report.sh ghostty working)"
assert_eq "$osc_fish_working" "$actual" "Ghostty falls back to fish_title when title query is unavailable"
rm -rf "$fish_runtime"

tmp_home="$(mktemp -d)"
cleanup() { rm -rf "$early_runtime" "$tmp_home" "${install_home:-}" "${adapter_home:-}"; }
trap cleanup EXIT
mkdir -p "$tmp_home/.config/agent-state/scripts" "$tmp_home/fake-bin" "$tmp_home/runtime"
cp scripts/*.sh "$tmp_home/.config/agent-state/scripts/"

cat > "$tmp_home/fake-bin/afplay" <<'AFPLAY'
#!/usr/bin/env bash
printf '%s\n' "$(basename "$1")" >> "$AGENT_SOUND_LOG"
AFPLAY
chmod +x "$tmp_home/fake-bin/afplay"
touch "$tmp_home/blocked.aiff" "$tmp_home/idle.aiff"
sound_log="$tmp_home/sound.log"
: > "$sound_log"
sound_env=(env -i HOME="$tmp_home" PATH="$tmp_home/fake-bin:$PATH" SHELL=/bin/sh TERM_PROGRAM=ghostty AGENT_GHOSTTY_FORCE_STDOUT=1 XDG_RUNTIME_DIR="$tmp_home/runtime" AGENT_GHOSTTY_STATE_KEY=contract AGENT_SOUND_BLOCKED="$tmp_home/blocked.aiff" AGENT_SOUND_IDLE="$tmp_home/idle.aiff" AGENT_SOUND_LOG="$sound_log")

actual="$(${sound_env[@]} bash scripts/agent-report.sh ghostty blocked)"
assert_eq "$osc_blocked" "$actual" "Ghostty blocked keeps title while playing sound"
wait_for_log "$sound_log" "blocked.aiff" "Ghostty blocked plays blocked sound"

"${sound_env[@]}" bash scripts/agent-report.sh ghostty blocked >/dev/null
line_count="$(wc -l < "$sound_log" | tr -d ' ')"
assert_eq "1" "$line_count" "Ghostty repeated blocked does not replay sound"

"${sound_env[@]}" bash scripts/agent-report.sh ghostty idle >/dev/null
line_count="$(wc -l < "$sound_log" | tr -d ' ')"
assert_eq "1" "$line_count" "Ghostty idle directly after blocked stays quiet"

"${sound_env[@]}" bash scripts/agent-report.sh ghostty working >/dev/null
"${sound_env[@]}" bash scripts/agent-report.sh ghostty idle >/dev/null
wait_for_log "$sound_log" "idle.aiff" "Ghostty idle after working plays idle sound"

key_runtime="$tmp_home/key-runtime"
mkdir -p "$key_runtime"
env -i HOME="$tmp_home" PATH="$tmp_home/fake-bin:$PATH" SHELL=/bin/sh TERM_PROGRAM=ghostty AGENT_GHOSTTY_FORCE_STDOUT=1 XDG_RUNTIME_DIR="$key_runtime" AGENT_SOUND_BLOCKED="$tmp_home/blocked.aiff" AGENT_SOUND_IDLE="$tmp_home/idle.aiff" AGENT_SOUND_LOG="$sound_log" bash scripts/agent-report.sh ghostty blocked >/dev/null
[ ! -e "$key_runtime/agent-state-ghostty/not_a_tty.state" ] || fail "Ghostty default state key used literal not_a_tty"
find "$key_runtime/agent-state-ghostty" -type f -name '*.state' | grep -q . || fail "Ghostty default state key did not create a state file"
printf 'ok - Ghostty default state key avoids not_a_tty collision\n'

hook_env=(env -i HOME="$tmp_home" PATH="$PATH" SHELL=/bin/sh TERM_PROGRAM=ghostty AGENT_GHOSTTY_FORCE_STDOUT=1)

actual="$(${hook_env[@]} bash scripts/hook-adapter.sh Stop </dev/null)"
assert_eq "$osc_idle" "$actual" "hook adapter routes Ghostty Stop to idle"

actual="$(printf '{"tool_name":"AskUserQuestion"}' | ${hook_env[@]} bash scripts/hook-adapter.sh PreToolUse)"
assert_eq "$osc_blocked" "$actual" "hook adapter routes Ghostty blocking tool to blocked"

install_home="$(mktemp -d)"
install_output="$(env -i HOME="$install_home" PATH="$PATH" TERM_PROGRAM=ghostty bash ./install.sh)"
[ -x "$install_home/.config/agent-state/scripts/ghostty-agent-report.sh" ] || fail "installer did not install Ghostty backend"
case "$install_output" in
  *"Ghostty detected"*|*"Zellij/Ghostty"*) ;;
  *) fail "installer did not mention Ghostty support" ;;
esac
env -i HOME="$install_home" PATH="$PATH" bash ./uninstall.sh >/dev/null
[ ! -e "$install_home/.config/agent-state/scripts/ghostty-agent-report.sh" ] || fail "uninstaller did not remove Ghostty backend"
printf 'ok - installer and uninstaller handle Ghostty backend\n'

adapter_home="$(mktemp -d)"
mkdir -p "$adapter_home/.config/agent-state/scripts"
cat > "$adapter_home/.config/agent-state/scripts/agent-report.sh" <<'REPORT'
#!/usr/bin/env bash
printf '<%s>|<%s>|<%s>\n' "${1-}" "${2-}" "${3-}" >> "$AGENT_REPORT_LOG"
REPORT
chmod +x "$adapter_home/.config/agent-state/scripts/agent-report.sh"

log="$adapter_home/report.log"
node_env=(env -i HOME="$adapter_home" PATH="$PATH" SHELL=/bin/sh TERM_PROGRAM=ghostty AGENT_REPORT_LOG="$log")

"${node_env[@]}" node --input-type=module <<'NODE'
const mod = await import(`file://${process.cwd()}/adapters/opencode/gentle-agent-state.js`);
const plugin = await mod.TmuxAgentStatePlugin();
if (typeof plugin["chat.message"] !== "function") {
  throw new Error("opencode plugin did not enable in native Ghostty");
}
await plugin["chat.message"]();
NODE
assert_eq "<ghostty>|<working>|<>" "$(cat "$log")" "opencode adapter reports Ghostty backend id"

: > "$log"
"${node_env[@]}" node --input-type=module <<'NODE'
const mod = await import(`file://${process.cwd()}/adapters/pi/gentle-agent-state.ts`);
const handlers = new Map();
const pi = { on(name, handler) { handlers.set(name, handler); } };
mod.default(pi);
if (!handlers.has("agent_start")) {
  throw new Error("pi extension did not enable in native Ghostty");
}
handlers.get("agent_start")();
await new Promise((resolve) => setTimeout(resolve, 100));
NODE
assert_eq "<ghostty>|<working>|<>" "$(cat "$log")" "pi adapter reports Ghostty backend id"

: > "$log"
"${node_env[@]}" node --input-type=module <<'NODE'
const mod = await import(`file://${process.cwd()}/adapters/pi/gentle-agent-state.ts`);
const handlers = new Map();
const pi = { on(name, handler) { handlers.set(name, handler); } };
mod.default(pi);
handlers.get("tool_call")?.({ id: "ask-1", toolName: "functions.ask_user_question" });
handlers.get("tool_execution_update")?.({ id: "ask-1", toolName: "functions.ask_user_question" });
await new Promise((resolve) => setTimeout(resolve, 100));
NODE
assert_eq "<ghostty>|<blocked>|<>" "$(cat "$log")" "pi prompt update keeps Ghostty blocked"
