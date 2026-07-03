#!/bin/bash
# resource-guard.sh — PreToolUse guard for agent/team/workflow spawns (Superboost v3.1)
# Part of Claude Code Superboost by ISYNCSO (https://isyncso.com)
#
# This is a PERFORMANCE guard (prevents thrashing a low-memory machine), NOT a
# security control. Two correctness rules that v3.0 got wrong:
#   1. Claude Code blocks a PreToolUse tool ONLY on exit code 2 (v3.0 used exit 1,
#      which never blocked). We exit 2 to actually deny.
#   2. Do NOT mask the resource-check exit status behind `|| echo` (v3.0 bug: the
#      `||` made the substitution succeed, so a hard block was never seen).
# Fail-OPEN by design: if the check can't run, warn but allow — never lock the
# user out of agents because a monitoring script hiccuped.
#
# Bind this to the Agent, TeamCreate, Task and Workflow PreToolUse matchers so all
# spawn paths share ONE implementation (v3.0 duplicated the logic in settings.json).

HOOK_LOG="${HOME}/.claude/logs/resource-guard.log"
mkdir -p "$(dirname "$HOOK_LOG")"

# Rotate our own log so it can't grow unbounded.
if [ -f "$HOOK_LOG" ] && [ "$(wc -c <"$HOOK_LOG" 2>/dev/null || echo 0)" -gt 262144 ]; then
  tail -n 500 "$HOOK_LOG" >"$HOOK_LOG.tmp" 2>/dev/null && mv "$HOOK_LOG.tmp" "$HOOK_LOG"
fi

TOOL_INPUT=$(cat)
TOOL_NAME=$(printf '%s' "$TOOL_INPUT" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('tool_name', d.get('name', '')))
except Exception:
    print('')
" 2>/dev/null)

# Only guard spawn tools; allow everything else unconditionally.
case "$TOOL_NAME" in
  Agent|TeamCreate|Task|Workflow|mcp__spawn-agent) : ;;
  *) exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK_JSON=$("${SCRIPT_DIR}/resource-check.sh" --quiet 2>/dev/null)   # capture output
CAN=$(printf '%s' "$CHECK_JSON" | python3 -c "
import json, sys
try:
    print(json.load(sys.stdin).get('can_spawn'))
except Exception:
    print('ERR')
" 2>/dev/null)

TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
echo "[$TS] tool=$TOOL_NAME can_spawn=$CAN json=$CHECK_JSON" >> "$HOOK_LOG"

if [ "$CAN" = "False" ]; then
  REASON=$(printf '%s' "$CHECK_JSON" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(f\"{d.get('reason','?')} (avail {d.get('available_gb','?')}GB)\")
except Exception:
    print('resources too low')
" 2>/dev/null)
  echo "BLOCKED: system resources too low to spawn safely — ${REASON}. Free memory or reduce parallelism, then retry." >&2
  exit 2   # exit 2 = block the tool (correct Claude Code hook semantics)
fi

# can_spawn true, or check unavailable → allow. Fail-open is acceptable here
# because this guards machine performance, not security.
if [ "$CAN" = "ERR" ]; then
  echo "resource-guard: resource-check unavailable; allowing spawn (unverified)." >&2
fi
exit 0
