#!/bin/bash
# superboost-statusline.sh — Persistent RAM meter for Claude Code Superboost
# Part of Claude Code Superboost by ISYNCSO (https://isyncso.com)
#
# Reads JSON session data on stdin, combines with live RAM stats.
# Outputs a single line for the Claude Code status bar.
# Save to: ~/.claude/hooks/superboost-statusline.sh

# --- Parse session JSON from stdin ---
INPUT=$(cat)
MODEL=$(echo "$INPUT" | jq -r '.model.display_name // "?"' 2>/dev/null)
MODEL_ID=$(echo "$INPUT" | jq -r '.model.id // ""' 2>/dev/null)
PCT=$(echo "$INPUT" | jq -r '.context_window.used_percentage // 0' 2>/dev/null | cut -d. -f1)
CTX_SIZE_RAW=$(echo "$INPUT" | jq -r '.context_window.context_window_size // 1000000' 2>/dev/null)
COST=$(echo "$INPUT" | jq -r '.cost.total_cost_usd // 0' 2>/dev/null)

# --- Fast mode detection (v3) ---
# /fast uses Opus 4.6 without extended thinking — incompatible with Pre-Flight Optimization.
# Surface a visual warning so the user remembers agent dispatch is solo-only in fast mode.
FAST_FLAG=""
case "$MODEL$MODEL_ID" in
  *"4.6"*|*"4-6"*)
    FAST_FLAG="\033[1;33m⚠ FAST\033[0m │ "
    ;;
esac

# Override known-buggy 200K report for Opus models (actual limit is 1M)
# See: https://github.com/anthropics/claude-code/issues/24208
CTX_SIZE="$CTX_SIZE_RAW"
case "$MODEL" in *Opus*|*opus*) [ "$CTX_SIZE" -le 200000 ] 2>/dev/null && CTX_SIZE=1000000 ;; esac

# Format context as K tokens
CTX_USED_K=$(awk "BEGIN {printf \"%.0f\", ($PCT / 100) * $CTX_SIZE / 1000}")
CTX_MAX_K=$(awk "BEGIN {printf \"%.0f\", $CTX_SIZE / 1000}")

# --- Get live RAM stats ---
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

AVAIL_GB=$(awk "BEGIN {printf \"%.1f\", $AVAIL_MB / 1024}")

# --- Calculate agent scaling (RAM-based, no artificial cap) ---
# Tiered safety margin: max(4096MB, total_ram * 15%) — matches resource-check.sh
SAFETY_MB=$(( TOTAL_MB * 15 / 100 ))
[ "$SAFETY_MB" -lt 4096 ] && SAFETY_MB=4096
PER_AGENT_MB="${RESOURCE_PER_AGENT_MB:-1000}"
MAX_AGENTS=$(( (AVAIL_MB - SAFETY_MB) / PER_AGENT_MB ))
[ "$MAX_AGENTS" -lt 0 ] && MAX_AGENTS=0
MAX_AGENT_CAP="${RESOURCE_MAX_AGENT_CAP:-20}"
[ "$MAX_AGENTS" -gt "$MAX_AGENT_CAP" ] && MAX_AGENTS="$MAX_AGENT_CAP"

# Count only CLI instances, not Desktop app or helpers
CLAUDE_PROCS=$(ps aux 2>/dev/null | grep -c "[[:space:]]claude[[:space:]]" || true)
HEADROOM=$(( MAX_AGENTS - CLAUDE_PROCS ))

# --- Build RAM bar (10 chars) ---
USED_PCT=$(( 100 - (AVAIL_MB * 100 / TOTAL_MB) ))
FILLED=$(( USED_PCT / 10 ))
EMPTY=$(( 10 - FILLED ))

BAR=""
for ((i=0; i<FILLED; i++)); do BAR="${BAR}█"; done
for ((i=0; i<EMPTY; i++)); do BAR="${BAR}░"; done

# --- Pick colors ---
if [ "$AVAIL_MB" -gt 8192 ]; then
  RAM_COLOR="\033[32m"  # green
elif [ "$AVAIL_MB" -gt 4096 ]; then
  RAM_COLOR="\033[33m"  # yellow
else
  RAM_COLOR="\033[31m"  # red
fi

# --- Agent scaling indicator ---
if [ "$HEADROOM" -gt 2 ]; then
  SCALE_IND="\033[32mup to ${MAX_AGENTS} agents\033[0m"
elif [ "$HEADROOM" -ge 0 ]; then
  SCALE_IND="\033[33m${MAX_AGENTS} agents (near limit)\033[0m"
else
  SCALE_IND="\033[31m${CLAUDE_PROCS} active (over capacity)\033[0m"
fi

# --- Format cost ---
if [ "$(echo "$COST > 0" | bc 2>/dev/null)" = "1" ]; then
  COST_STR=$(printf '$%.2f' "$COST")
  COST_PART=" │ ${COST_STR}"
else
  COST_PART=""
fi

# --- Output status line (compact — leave room for Claude's context indicator) ---
echo -e "ISYNCSO ⚡ SUPERBOOST │ ${FAST_FLAG}RAM: ${RAM_COLOR}${BAR}\033[0m ${USED_PCT}% │ ${RAM_COLOR}${AVAIL_GB}GB free\033[0m │ ${SCALE_IND} │ ${MODEL}${COST_PART}"
