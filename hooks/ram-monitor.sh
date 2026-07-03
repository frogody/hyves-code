#!/bin/bash
# ram-monitor.sh — PostToolUse RAM monitor (Superboost v3.1)
# Part of Claude Code Superboost by ISYNCSO (https://isyncso.com)
# Fires after every tool call. v3.1 changes vs v3.0:
#   - Log ROTATION: cap the file so it can't grow unbounded (v3.0 reached 39MB / 200k lines).
#   - SAMPLED logging: only write a routine line every Nth call (or on threshold approach),
#     cutting write-amplification ~90% while still catching pressure events every call.
# Alerts (stderr) still fire on EVERY call so nothing is missed.

LOGDIR="$HOME/.claude/logs"
LOGFILE="$LOGDIR/ram-monitor.log"
COUNTER_FILE="$LOGDIR/.ram-counter"
SAMPLE_EVERY="${RAM_MONITOR_SAMPLE_EVERY:-10}"   # write a routine line 1-in-N calls
MAX_LOG_BYTES="${RAM_MONITOR_MAX_LOG_BYTES:-524288}"  # 512KB cap
mkdir -p "$LOGDIR"

# --- Fast check: platform-specific memory stats (~20-25ms including memory_pressure) ---
if [ "$(uname)" = "Darwin" ]; then
  PAGE_SIZE=$(sysctl -n hw.pagesize 2>/dev/null || echo 16384)
  VM=$(vm_stat 2>/dev/null)
  FREE_P=$(echo "$VM" | awk '/^Pages free:/ {gsub(/[^0-9]/,"",$3); print $3+0}')
  INACT_P=$(echo "$VM" | awk '/^Pages inactive:/ {gsub(/[^0-9]/,"",$3); print $3+0}')
  PURG_P=$(echo "$VM" | awk '/^Pages purgeable:/ {gsub(/[^0-9]/,"",$3); print $3+0}')
  SPEC_P=$(echo "$VM" | awk '/^Pages speculative:/ {gsub(/[^0-9]/,"",$3); print $3+0}')
  AVAIL_MB=$(( (FREE_P + INACT_P + PURG_P + SPEC_P) * PAGE_SIZE / 1024 / 1024 ))
  MEM_PCT=$(memory_pressure 2>/dev/null | awk '/free percentage/ {gsub(/%/,"",$NF); print $NF+0}' || echo 50)
# Linux
else
  AVAIL_MB=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
  TOTAL=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 1)
  MEM_PCT=$(( AVAIL_MB * 100 / TOTAL ))
fi

# --- Increment counter for sampling + periodic heavy check ---
COUNT=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
COUNT=$((COUNT + 1))
echo "$COUNT" > "$COUNTER_FILE"

# --- Rotate log if it exceeds the cap (keep the tail) ---
if [ -f "$LOGFILE" ] && [ "$(wc -c <"$LOGFILE" 2>/dev/null || echo 0)" -gt "$MAX_LOG_BYTES" ]; then
  tail -n 1000 "$LOGFILE" > "$LOGFILE.tmp" 2>/dev/null && mv "$LOGFILE.tmp" "$LOGFILE"
fi

# --- Decide whether to write a routine line: sample, but always log near-threshold ---
NEAR_THRESHOLD=0
[ "${MEM_PCT:-50}" -lt 25 ] && NEAR_THRESHOLD=1
if [ $((COUNT % SAMPLE_EVERY)) -eq 0 ] || [ "$NEAR_THRESHOLD" -eq 1 ]; then
  PROC_INFO=""
  if [ $((COUNT % 100)) -eq 0 ]; then
    TOP_PROCS=$(ps -eo rss,comm 2>/dev/null | awk '{mem[$2]+=$1} END {for(p in mem) if(mem[p]>100000) printf "%s=%.0fMB ", p, mem[p]/1024}')
    PROC_INFO=" procs=[$TOP_PROCS]"
  fi
  TIMESTAMP=$(date -u +%H:%M:%S)
  echo "$TIMESTAMP avail=${AVAIL_MB}MB mem_free=${MEM_PCT}%${PROC_INFO}" >> "$LOGFILE"
fi

# --- Alert thresholds (checked every call) ---
if [ "${MEM_PCT:-50}" -lt 10 ]; then
  echo "CRITICAL: Memory pressure at ${MEM_PCT}% free (${AVAIL_MB}MB available). Consider shutting down agents to prevent system instability." >&2
  exit 2
elif [ "${MEM_PCT:-50}" -lt 20 ]; then
  echo "WARNING: Memory pressure dropping — ${MEM_PCT}% free (${AVAIL_MB}MB available). Monitor closely." >&2
fi

exit 0
