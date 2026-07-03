#!/usr/bin/env bash
# lumos-complete.sh — Mark a Lumos Maxima job as completed with stats
# Usage: lumos-complete.sh <job_id> <stats_json_file_or_inline>
#
# The stats JSON should contain:
# {
#   "companies_input": 1127,
#   "companies_researched": 500,
#   "tiers": {"A": 57, "B": 202, "C": 172, "D": 69},
#   "false_positives_flagged": 18,
#   "verticals": {"B2B SaaS": {"count": 225, "quota": 225}, ...},
#   "scoring_model": "12_dimension",
#   "max_score": 24,
#   "agents": {"research": 20, "analyst": 2, "total_sessions": 86},
#   "tokens": {"input": 2080000, "output": 1370000, "total_fresh": 3450000},
#   "web_searches": 2942,
#   "api_cost_usd": 2375,
#   "wall_clock_hrs": 6.6,
#   "campaign_segments": [...],
#   "top_companies": [...]
# }
#
# Example:
#   lumos-complete.sh abc-123 ./run_stats.json
#   lumos-complete.sh abc-123 '{"companies_researched":500,"tiers":{"A":57}}'

set -euo pipefail

JOB_ID="${1:?Usage: lumos-complete.sh <job_id> <stats_json_or_file>}"
STATS_INPUT="${2:?Missing stats JSON or file path}"
TOKEN="${SUPABASE_ACCESS_TOKEN:?Set SUPABASE_ACCESS_TOKEN env var}"
PROJECT="${SUPABASE_PROJECT_ID:-sfxpmzicgpaxfntqleig}"
API="https://api.supabase.com/v1/projects/${PROJECT}/database/query"
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Read stats from file or inline
if [ -f "$STATS_INPUT" ]; then
  STATS_JSON=$(cat "$STATS_INPUT")
else
  STATS_JSON="$STATS_INPUT"
fi

# Validate it's valid JSON
if ! echo "$STATS_JSON" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
  echo "✗ Invalid JSON stats" >&2
  exit 1
fi

# Escape for SQL
STATS_ESC=$(echo "$STATS_JSON" | python3 -c "import sys; print(sys.stdin.read().replace(\"'\", \"''\"))")

# Mark stage_history final entries as completed
SQL="
UPDATE public.lumos_maxima_jobs
SET
  status = 'completed',
  progress_pct = 100,
  current_stage = 'completed',
  processing_completed_at = '${NOW}'::timestamptz,
  stats = '${STATS_ESC}'::jsonb,
  progress_notes = 'Run complete. All deliverables uploaded.',
  -- Mark last stage entry as completed
  stage_history = CASE
    WHEN stage_history IS NOT NULL AND jsonb_array_length(stage_history) > 0
    THEN jsonb_set(
      stage_history,
      ARRAY[(jsonb_array_length(stage_history) - 1)::text],
      (stage_history->-1 || jsonb_build_object('completed_at', '${NOW}'))
    )
    ELSE stage_history
  END,
  updated_at = now()
WHERE id = '${JOB_ID}'::uuid
RETURNING id, status, progress_pct, processing_started_at, processing_completed_at;
"

RESULT=$(curl -s -X POST "$API" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d "$(python3 -c "import json,sys; print(json.dumps({'query': sys.stdin.read()}))" <<< "$SQL")")

# Extract timing
STARTED=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)[0].get('processing_started_at','?'))" 2>/dev/null || echo "?")
COMPLETED=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)[0].get('processing_completed_at','?'))" 2>/dev/null || echo "?")

echo ""
echo "═══════════════════════════════════════════════"
echo " LUMOS MAXIMA — RUN COMPLETE"
echo "═══════════════════════════════════════════════"
echo " Job:       ${JOB_ID}"
echo " Started:   ${STARTED}"
echo " Completed: ${COMPLETED}"
echo " Status:    completed (100%)"
echo "═══════════════════════════════════════════════"
echo ""
echo "Deliverables are ready in /admin → Lumos Maxima."

# ── Universe Recapture (auto-triggered if LUMOS_JOB_ID is set) ──
ENGINE_DIR="/Users/godyduinsbergen/Downloads/isyncso-commercial-engine"
RECAPTURE_SCRIPT="${ENGINE_DIR}/universe_recapture.py"

# Detect client directory from LUMOS_CLIENT_DIR env or by finding the most recent client dir
CLIENT_DIR="${LUMOS_CLIENT_DIR:-}"
if [ -z "$CLIENT_DIR" ]; then
  # Try to find the client dir from the job's client_name
  CLIENT_NAME_DB=$(curl -s -X POST "$API" \
    -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' \
    -d "{\"query\": \"SELECT client_name FROM lumos_maxima_jobs WHERE id = '${JOB_ID}'::uuid\"}" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['client_name'] if d else '')" 2>/dev/null || echo "")
  if [ -n "$CLIENT_NAME_DB" ] && [ -d "${ENGINE_DIR}/${CLIENT_NAME_DB}" ]; then
    CLIENT_DIR="${ENGINE_DIR}/${CLIENT_NAME_DB}"
  fi
fi

if [ -n "$CLIENT_DIR" ] && [ -f "$RECAPTURE_SCRIPT" ] && [ -d "${CLIENT_DIR}/research_results" ]; then
  echo ""
  echo "Starting universe recapture..."

  # Mark recapture as running
  curl -s -X POST "$API" \
    -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' \
    -d "{\"query\": \"UPDATE lumos_maxima_jobs SET recapture_status = 'running', updated_at = NOW() WHERE id = '${JOB_ID}'::uuid\"}" > /dev/null

  # Run recapture with lumos writeback
  python3 "$RECAPTURE_SCRIPT" "$CLIENT_DIR" --lumos-job-id "$JOB_ID" --lumos-writeback || {
    echo "Warning: Universe recapture failed (non-blocking)"
    curl -s -X POST "$API" \
      -H "Authorization: Bearer $TOKEN" \
      -H 'Content-Type: application/json' \
      -d "{\"query\": \"UPDATE lumos_maxima_jobs SET recapture_status = 'failed', updated_at = NOW() WHERE id = '${JOB_ID}'::uuid\"}" > /dev/null
  }
else
  echo ""
  echo "Skipping universe recapture (no client dir or research results found)"
  echo "  CLIENT_DIR: ${CLIENT_DIR:-not set}"
  echo "  To run manually: python3 ${RECAPTURE_SCRIPT} <client_dir> --lumos-job-id ${JOB_ID} --lumos-writeback"
fi
