// gentle-agent-state — pi adapter for the agent-state notifier.
// Translates pi's native lifecycle events into the canonical vocabulary and
// forwards them to the neutral multiplexer core (~/.config/agent-state/scripts/agent-report.sh).
//
// Active only inside a tmux/Zellij pane (and NOT under herdr/subagent children).
// @ts-nocheck

import { spawn } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";

const REPORT = join(homedir(), ".config", "agent-state", "scripts", "agent-report.sh");
const pane = process.env.TMUX_PANE ?? process.env.ZELLIJ_PANE_ID;
const enabled = Boolean(pane) && process.env.HERDR_ENV !== "1" && process.env.PI_SUBAGENT_CHILD !== "1";

function report(state) {
  if (!pane) return;
  const child = spawn("bash", [REPORT, pane, state], { stdio: "ignore" });
  child.on("error", () => {});
}

function toolName(ev) {
  return String(ev?.toolName ?? ev?.name ?? ev?.tool?.name ?? "");
}

function isBlockingTool(ev) {
  const name = toolName(ev).toLowerCase().replace(/[^a-z0-9]/g, "");
  return (
    name.endsWith("askuserquestion") ||
    name.endsWith("requestuserinput") ||
    name.endsWith("exitplanmode") ||
    name.includes("confirm")
  );
}

function toolCallId(ev) {
  return String(ev?.toolCallId ?? ev?.id ?? "");
}

function toolInput(ev) {
  return ev?.input ?? ev?.args ?? ev?.tool?.input ?? {};
}

function isBashTool(ev) {
  const name = toolName(ev).toLowerCase().replace(/[^a-z0-9]/g, "");
  return name.endsWith("bash");
}

function isGuardedBashTool(ev) {
  if (!isBashTool(ev)) return false;
  const command = String(toolInput(ev)?.command ?? "");
  return [
    /\bgit(?:\s+--?\S+(?:\s+[^-\s]\S*)?)*\s+push\b/,
    /\bgit\s+rebase\b/,
    /\bgit\s+branch\s+(?:-[a-zA-Z]*D[a-zA-Z]*|-[a-zA-Z]*d[a-zA-Z]*f[a-zA-Z]*|-[a-zA-Z]*f[a-zA-Z]*d[a-zA-Z]*|--delete\b[^\n]*--force\b|--force\b[^\n]*--delete\b)/,
    /\bnpm\s+publish\b/,
    /\bpi\s+remove\b/,
    /\brm\s+-rf\s+(?:\/(?:\s|$)|~(?:\/|\s|$)|[$]HOME(?:\/|\s|$)|\.\.?(?:\s|$))/,
    /\bgit\s+reset\s+--hard\b/,
    /\bgit\s+clean\b(?=[^\n]*(?:-[^\n]*f|--force))(?=[^\n]*(?:-[^\n]*d|--directories))/,
    /\bchmod\s+-R\s+777\b/,
    /\bchown\s+-R\b/,
  ].some((pattern) => pattern.test(command));
}

export default function (pi) {
  if (!enabled) return;

  let active = false;
  let idleTimer;

  const clearIdle = () => {
    if (idleTimer) clearTimeout(idleTimer);
    idleTimer = undefined;
  };

  pi.on?.("session_start", () => report("idle"));

  pi.on?.("agent_start", () => {
    active = true;
    clearIdle();
    report("working");
  });

  pi.on?.("agent_end", () => {
    active = false;
    clearIdle();
    // debounce so provider retries / quick back-to-back turns don't flash idle
    idleTimer = setTimeout(() => report("idle"), 250);
    idleTimer.unref?.();
  });

  // blocked = pi is waiting on the user. Pi user prompts are surfaced through
  // tools/events rather than a dedicated lifecycle event. Match normalized tool
  // names so namespaced forms like `functions.ask_user_question` work too.
  const guardedToolCalls = new Set();

  const markBlockedIfNeeded = (ev) => {
    if (isBlockingTool(ev) || isGuardedBashTool(ev)) {
      const id = toolCallId(ev);
      if (id) guardedToolCalls.add(id);
      clearIdle();
      report("blocked");
    }
  };

  const markWorkingIfBlockedToolContinues = (ev) => {
    const id = toolCallId(ev);
    if ((id && guardedToolCalls.has(id)) || isBlockingTool(ev)) {
      if (id) guardedToolCalls.delete(id);
      report("working"); // prompt answered or guarded bash started producing output
    }
  };

  pi.on?.("tool_execution_start", markBlockedIfNeeded);

  pi.on?.("tool_call", markBlockedIfNeeded);

  pi.on?.("tool_execution_update", markWorkingIfBlockedToolContinues);

  pi.on?.("tool_result", markWorkingIfBlockedToolContinues);

  pi.on?.("tool_execution_end", markWorkingIfBlockedToolContinues);

  pi.on?.("session_shutdown", () => {
    clearIdle();
    report("idle");
  });
}
