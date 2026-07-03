#!/bin/bash
# resource-check.sh — Pre-spawn resource health check for Claude Code agent teams
# Part of Claude Code Superboost by ISYNCSO (https://isyncso.com)
# Platform: macOS (Apple Silicon + Intel) and Linux
# Calibrated: MacBook Pro M1 Max 64GB — measured 874MB (idle) to 1190MB (active) per agent
#
# Usage: ./resource-check.sh [--min-agents N] [--quiet]
# Exit codes: 0 = safe, 1 = blocked (hard limit), 2 = warning (proceed with caution)
# Output with --quiet: JSON for hook consumption
# Save to: ~/.claude/hooks/resource-check.sh

# --- Configuration (overridable via environment) ---
MIN_AVAILABLE_GB="${RESOURCE_MIN_AVAILABLE_GB:-8}"       # Hard block below this
WARN_AVAILABLE_GB="${RESOURCE_WARN_AVAILABLE_GB:-16}"    # Warn below this
MAX_LOAD_THRESHOLD="${RESOURCE_MAX_LOAD:-14.0}"          # 10 cores * 1.4
PER_AGENT_MB="${RESOURCE_PER_AGENT_MB:-1000}"            # Measured: 874-1190MB range
MAX_AGENT_CAP="${RESOURCE_MAX_AGENT_CAP:-20}"             # Dynamic cap — coordinator manages rate budget
MIN_AGENTS=1
QUIET=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --min-agents) MIN_AGENTS="$2"; shift 2 ;;
        --quiet|-q) QUIET=true; shift ;;
        *) shift ;;
    esac
done

# --- Helpers ---
RED='\033[0;31m'; YELLOW='\033[0;33m'; GREEN='\033[0;32m'; NC='\033[0m'
log()  { $QUIET || echo -e "$@"; }
warn() { $QUIET || echo -e "${YELLOW}WARNING: $1${NC}" >&2; }
err()  { echo -e "${RED}ERROR: $1${NC}" >&2; }

# --- Platform-specific resource detection ---
if [ "$(uname)" = "Darwin" ]; then
    # macOS: vm_stat for memory pages, memory_pressure for system state
    PAGE_SIZE=$(sysctl -n hw.pagesize 2>/dev/null || echo 16384)
    VM=$(vm_stat 2>/dev/null)
    FREE_P=$(echo "$VM"     | awk '/^Pages free:/        {gsub(/[^0-9]/,"",$3); print $3+0}')
    INACT_P=$(echo "$VM"    | awk '/^Pages inactive:/    {gsub(/[^0-9]/,"",$3); print $3+0}')
    PURG_P=$(echo "$VM"     | awk '/^Pages purgeable:/   {gsub(/[^0-9]/,"",$3); print $3+0}')
    SPEC_P=$(echo "$VM"     | awk '/^Pages speculative:/ {gsub(/[^0-9]/,"",$3); print $3+0}')
    AVAIL_MB=$(( (FREE_P + INACT_P + PURG_P + SPEC_P) * PAGE_SIZE / 1024 / 1024 ))
    TOTAL_MB=$(( $(sysctl -n hw.memsize) / 1024 / 1024 ))
    LOAD_AVG=$(uptime 2>/dev/null | awk -F'load averages:' '{print $2}' | awk '{gsub(/,/,""); print $1}')
    SWAP_USED=$(sysctl -n vm.swapusage 2>/dev/null | awk '{gsub(/[^0-9.]/,"",$4); print $4+0}')
    MEM_PRESSURE=$(memory_pressure 2>/dev/null | awk '/free percentage/ {gsub(/%/,"",$NF); print $NF+0}' || echo 50)
else
    # Linux: /proc/meminfo for memory, /proc/loadavg for CPU, /proc/swaps for swap
    AVAIL_MB=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
    TOTAL_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
    LOAD_AVG=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)
    SWAP_USED=$(awk 'NR>1 {total+=$3-$4} END {print int(total/1024)}' /proc/swaps 2>/dev/null || echo 0)
    # Approximate memory pressure as available/total percentage
    if [ "$TOTAL_MB" -gt 0 ]; then
        MEM_PRESSURE=$(( AVAIL_MB * 100 / TOTAL_MB ))
    else
        MEM_PRESSURE=50
    fi
fi

AVAIL_GB=$(echo "scale=1; $AVAIL_MB / 1024" | bc 2>/dev/null || awk "BEGIN {printf \"%.1f\", $AVAIL_MB / 1024}")

# --- Active claude CLI processes (INFORMATIONAL ONLY in v4.0) ---
# NOTE: with teammateMode:in-process, spawned agents run inside the host process
# and do NOT appear as separate `claude` OS processes, so this count no longer
# reflects agent concurrency. Kept for observability; it is no longer a hard block.
CLAUDE_PROCS=$(pgrep -f '[c]laude' 2>/dev/null | wc -l | tr -d ' ')
[ -z "$CLAUDE_PROCS" ] && CLAUDE_PROCS=0

# --- Compute safe spawn count ---
# Tiered safety margin: max(4096MB, total_ram * 15%) — scales with machine size
SAFETY_MARGIN_MB=$(( TOTAL_MB * 15 / 100 ))
[ "$SAFETY_MARGIN_MB" -lt 4096 ] && SAFETY_MARGIN_MB=4096
REQUIRED_MB=$(( MIN_AGENTS * PER_AGENT_MB + SAFETY_MARGIN_MB ))
REQUIRED_GB=$(echo "scale=1; $REQUIRED_MB / 1024" | bc 2>/dev/null || awk "BEGIN {printf \"%.1f\", $REQUIRED_MB / 1024}")
MAX_NEW=$(( (AVAIL_MB - SAFETY_MARGIN_MB) / PER_AGENT_MB ))
[ "$MAX_NEW" -lt 0 ] && MAX_NEW=0
[ "$MAX_NEW" -gt "$MAX_AGENT_CAP" ] && MAX_NEW=$MAX_AGENT_CAP

log ""
log "=== Claude Agent Spawn Check ==="
log "Available RAM:   ${AVAIL_GB} GB  (need ${REQUIRED_GB} GB for ${MIN_AGENTS} agent(s))"
log "Active agents:   ${CLAUDE_PROCS}  (rate-limit cap: ${MAX_AGENT_CAP})"
log "Load average:    ${LOAD_AVG}  (threshold: ${MAX_LOAD_THRESHOLD})"
log "Memory pressure: ${MEM_PRESSURE}% free"
log "Swap used:       ${SWAP_USED:-0} MB"
log ""

EXIT_CODE=0
REASON="OK"

# --- Hard blocks ---
if [[ "${SWAP_USED:-0}" =~ ^[0-9]+$ ]] && [ "${SWAP_USED:-0}" -gt 100 ]; then
    err "BLOCKED: System is swapping (${SWAP_USED}MB). Spawning will cause degradation."
    REASON="swapping"; EXIT_CODE=1
fi

if [ "$AVAIL_MB" -lt "$(( MIN_AVAILABLE_GB * 1024 ))" ]; then
    err "BLOCKED: Insufficient RAM. Have ${AVAIL_GB}GB, need ${MIN_AVAILABLE_GB}GB minimum."
    REASON="low_ram:${AVAIL_GB}GB"; EXIT_CODE=1
fi

if [ "$AVAIL_MB" -lt "$REQUIRED_MB" ]; then
    err "BLOCKED: Not enough RAM for ${MIN_AGENTS} agent(s). Have ${AVAIL_GB}GB, need ${REQUIRED_GB}GB."
    REASON="insufficient_for_count:${MIN_AGENTS}"; EXIT_CODE=1
fi

if [ "$CLAUDE_PROCS" -ge "$MAX_AGENT_CAP" ]; then
    err "BLOCKED: ${CLAUDE_PROCS} agents already running (rate-limit cap: ${MAX_AGENT_CAP})."
    REASON="rate_limit_cap"; EXIT_CODE=1
fi

if [ "${MEM_PRESSURE:-50}" -lt 5 ]; then
    err "BLOCKED: Memory pressure critical (${MEM_PRESSURE}% free)."
    REASON="critical_pressure"; EXIT_CODE=1
fi

# --- Soft warnings ---
LOAD_INT="${LOAD_AVG%%.*}"
MAX_INT="${MAX_LOAD_THRESHOLD%%.*}"
if [ "${LOAD_INT:-0}" -gt "${MAX_INT:-14}" ] && [ "$EXIT_CODE" -eq 0 ]; then
    warn "High CPU load (${LOAD_AVG} > ${MAX_LOAD_THRESHOLD}). Agents may be slower."
    EXIT_CODE=2
fi

if [ "$AVAIL_MB" -lt "$(( WARN_AVAILABLE_GB * 1024 ))" ] && [ "$EXIT_CODE" -eq 0 ]; then
    warn "Low available RAM (${AVAIL_GB}GB < ${WARN_AVAILABLE_GB}GB recommended)."
    EXIT_CODE=2
fi

# --- Summary ---
case $EXIT_CODE in
    0) log "${GREEN}OK: Safe to spawn ${MIN_AGENTS} agent(s). ${AVAIL_GB}GB available, ${MAX_NEW} more agents possible.${NC}" ;;
    2) log "${YELLOW}WARN: Suboptimal conditions but proceeding. ${AVAIL_GB}GB available.${NC}" ;;
    1) log "${RED}BLOCKED: Cannot spawn. Reason: ${REASON}${NC}" ;;
esac

# Machine-readable JSON (always output — hooks and docs both rely on this)
SAFE=$( [ "$EXIT_CODE" -le 2 ] && [ "$EXIT_CODE" -ne 1 ] && echo "true" || echo "false" )
JSON="{\"can_spawn\":${SAFE},\"reason\":\"${REASON}\",\"available_ram_mb\":${AVAIL_MB},\"available_gb\":${AVAIL_GB},\"total_ram_mb\":${TOTAL_MB},\"cpu_load\":\"${LOAD_AVG}\",\"claude_processes\":${CLAUDE_PROCS},\"max_new_agents\":${MAX_NEW},\"memory_pressure_pct\":${MEM_PRESSURE},\"exit\":${EXIT_CODE}}"
log ""
log "JSON:"
log "$JSON"
if $QUIET; then
    echo "$JSON"
fi

exit $EXIT_CODE
