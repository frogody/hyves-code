#!/bin/bash
# resource-guard.sh — PreToolUse hook: blocks agent spawning when resources are low
# Part of Claude Code Superboost by ISYNCSO (https://isyncso.com)
# Claude Code hooks: exit 0 = allow, non-zero exit = block (stderr shown to Claude)
#
# Configure in ~/.claude/settings.json:
# {
#   "hooks": {
#     "PreToolUse": [{
#       "matcher": "TeamCreate",
#       "hooks": [{"type": "command", "command": "~/.claude/hooks/resource-guard.sh"}]
#     }]
#   }
# }
# Save to: ~/.claude/hooks/resource-guard.sh

HOOK_LOG="${HOME}/.claude/logs/resource-guard.log"
mkdir -p "$(dirname "$HOOK_LOG")"

# Read tool call JSON from stdin
TOOL_INPUT=$(cat)

# Extract tool name — Claude Code passes JSON with tool_name field
TOOL_NAME=$(echo "$TOOL_INPUT" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('tool_name', d.get('name', '')))
except:
    print('')
" 2>/dev/null || echo "")

# Only guard spawning operations; allow everything else
case "$TOOL_NAME" in
    TeamCreate|Agent|mcp__spawn-agent)
        : # fall through to check
        ;;
    *)
        exit 0  # allow non-spawn tools unconditionally
        ;;
esac

# Run resource check (quiet mode = JSON output)
SCRIPT_DIR="$(dirname "$0")"
CHECK_JSON=$("${SCRIPT_DIR}/resource-check.sh" --quiet 2>/dev/null || echo '{"can_spawn":false,"reason":"check_failed","exit":1}')
CHECK_EXIT=$?

# Log result
TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
echo "[$TIMESTAMP] Tool=$TOOL_NAME Check=$CHECK_JSON" >> "$HOOK_LOG"

if [ "$CHECK_EXIT" -eq 1 ]; then
    # Hard block
    REASON=$(echo "$CHECK_JSON" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    avail = d.get('available_gb', '?')
    reason = d.get('reason', 'unknown')
    procs = d.get('claude_processes', '?')
    print(f'Resource check blocked spawn: {reason}. Available: {avail}GB, Active agents: {procs}.')
except:
    print('Resource check failed — spawn blocked.')
" 2>/dev/null || echo "Spawn blocked: insufficient resources.")
    echo "$REASON" >&2
    exit 1
fi

# exit 2 = warning, still allow
exit 0
