#!/bin/bash
# superboost-statusline.sh — Persistent RAM/model HUD for Claude Code Superboost (v4.0)
# Part of Claude Code Superboost by ISYNCSO (https://isyncso.com)
#
# v4.0 changes vs v3.0:
#   - PURE ASCII, NO escape sequences / emoji.  v3.0 emitted raw \033[ ANSI color
#     codes and a wide '⚡' emoji. In fullscreen TUI mode Claude Code computes the
#     statusline's DISPLAY WIDTH to lay out the input line; ANSI escapes and
#     ambiguous-width glyphs corrupt that width, which desyncs mouse-coordinate
#     mapping and leaks SGR mouse reports (e.g. "<65;56;31M") into the prompt.
#     Plain ASCII => correct width => no leak.
#   - REMOVED the "FAST" flag (keyed off "4.6"; wrong premise, false-positived Sonnet).
#   - REMOVED process-count "active agents" fiction (in-process teammates aren't
#     separate processes); shows RAM headroom as a capacity hint only.
#
# Reads session JSON on stdin; outputs a single plain-text status-bar line.

INPUT=$(cat)
MODEL=$(echo "$INPUT" | jq -r '.model.display_name // "?"' 2>/dev/null)
COST=$(echo "$INPUT" | jq -r '.cost.total_cost_usd // 0' 2>/dev/null)

# --- Live RAM stats ---
if [ "$(uname)" = "Darwin" ]; then
  PAGE_SIZE=$(sysctl -n hw.pagesize 2>/dev/null || echo 16384)
  VM=$(vm_stat 2>/dev/null)
  FREE_P=$(echo "$VM" | awk '/^Pages free:/ {gsub(/[^0-9]/,"",$3); print $3+0}')
  INACT_P=$(echo "$VM" | awk '/^Pages inactive:/ {gsub(/[^0-9]/,"",$3); print $3+0}')
  PURG_P=$(echo "$VM" | awk '/^Pages purgeable:/ {gsub(/[^0-9]/,"",$3); print $3+0}')
  SPEC_P=$(echo "$VM" | awk '/^Pages speculative:/ {gsub(/[^0-9]/,"",$3); print $3+0}')
  AVAIL_MB=$(( (FREE_P + INACT_P + PURG_P + SPEC_P) * PAGE_SIZE / 1024 / 1024 ))
  TOTAL_MB=$(( $(sysctl -n hw.memsize) / 1024 / 1024 ))
else
  AVAIL_MB=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
  TOTAL_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
fi
[ "${TOTAL_MB:-0}" -lt 1 ] && TOTAL_MB=1

AVAIL_GB=$(awk "BEGIN {printf \"%.1f\", $AVAIL_MB / 1024}")

# --- RAM headroom as a capacity hint (RAM-based, no process counting) ---
SAFETY_MB=$(( TOTAL_MB * 15 / 100 )); [ "$SAFETY_MB" -lt 4096 ] && SAFETY_MB=4096
PER_AGENT_MB="${RESOURCE_PER_AGENT_MB:-1000}"
MAX_AGENTS=$(( (AVAIL_MB - SAFETY_MB) / PER_AGENT_MB )); [ "$MAX_AGENTS" -lt 0 ] && MAX_AGENTS=0
MAX_AGENT_CAP="${RESOURCE_MAX_AGENT_CAP:-20}"
[ "$MAX_AGENTS" -gt "$MAX_AGENT_CAP" ] && MAX_AGENTS="$MAX_AGENT_CAP"

# --- ASCII RAM bar (10 chars, no unicode) ---
USED_PCT=$(( 100 - (AVAIL_MB * 100 / TOTAL_MB) ))
[ "$USED_PCT" -lt 0 ] && USED_PCT=0; [ "$USED_PCT" -gt 100 ] && USED_PCT=100
FILLED=$(( USED_PCT / 10 )); EMPTY=$(( 10 - FILLED ))
BAR=""
for ((i=0; i<FILLED; i++)); do BAR="${BAR}#"; done
for ((i=0; i<EMPTY; i++)); do BAR="${BAR}-"; done

if [ "$MAX_AGENTS" -ge 3 ]; then CAP="RAM for ~${MAX_AGENTS} agents"
elif [ "$MAX_AGENTS" -ge 1 ]; then CAP="RAM tight (~${MAX_AGENTS})"
else CAP="low RAM - solo"; fi

COST_PART=""
if [ "$(echo "$COST > 0" | bc 2>/dev/null)" = "1" ]; then
  COST_PART=" | $(printf '$%.2f' "$COST")"
fi

# Plain ASCII, single line, no escape sequences.
printf 'SUPERBOOST | RAM [%s] %s%% | %sGB free | %s | %s%s\n' \
  "$BAR" "$USED_PCT" "$AVAIL_GB" "$CAP" "$MODEL" "$COST_PART"
