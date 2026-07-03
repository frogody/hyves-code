#!/usr/bin/env bash
# lumos-progress.sh — Update Lumos Maxima job progress in Supabase
# Usage: lumos-progress.sh <job_id> <stage> <progress_pct> [notes]
#
# Stages: stage_2_batch_prep, stage_3_research, stage_4_merge,
#          stage_5_analysis, stage_6_enrichment, stage_7_reports
#
# Examples:
#   lumos-progress.sh abc-123 stage_3_research 35 "7/20 batches complete"
#   lumos-progress.sh abc-123 stage_4_merge 72 "Merging 20 batch results"

set -euo pipefail

JOB_ID="${1:?Usage: lumos-progress.sh <job_id> <stage> <progress_pct> [notes]}"
STAGE="${2:?Missing stage}"
PROGRESS="${3:?Missing progress_pct}"
NOTES="${4:-}"
TOKEN="${SUPABASE_ACCESS_TOKEN:?Set SUPABASE_ACCESS_TOKEN env var}"
PROJECT="${SUPABASE_PROJECT_ID:-sfxpmzicgpaxfntqleig}"
API="https://api.supabase.com/v1/projects/${PROJECT}/database/query"
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Build SQL safely via Python (handles quoting/escaping)
SQL=$(python3 -c "
import json, sys
job_id = sys.argv[1]
stage = sys.argv[2]
progress = int(sys.argv[3])
notes = sys.argv[4] if len(sys.argv) > 4 else ''
now = sys.argv[5]

# Escape for PostgreSQL string literals
notes_safe = notes.replace(\"'\", \"''\")

sql = f'''
UPDATE public.lumos_maxima_jobs
SET
  current_stage = '{stage}',
  progress_pct = {progress},
  progress_notes = '{notes_safe}',
  status = CASE
    WHEN status IN ('validated','input_received','draft') THEN 'processing'
    ELSE status
  END,
  processing_started_at = CASE
    WHEN processing_started_at IS NULL THEN '{now}'::timestamptz
    ELSE processing_started_at
  END,
  stage_history = CASE
    WHEN stage_history IS NOT NULL
      AND jsonb_array_length(stage_history) > 0
      AND stage_history->-1->>''stage'' = '{stage}'
    THEN jsonb_set(
      stage_history,
      ARRAY[(jsonb_array_length(stage_history) - 1)::text],
      (stage_history->-1 || jsonb_build_object(
        ''progress'', {progress},
        ''notes'', '{notes_safe}',
        ''updated_at'', '{now}'
      ))
    )
    ELSE COALESCE(stage_history, ''[]''::jsonb) || jsonb_build_object(
      ''stage'', '{stage}',
      ''started_at'', '{now}',
      ''progress'', {progress},
      ''notes'', '{notes_safe}'
    )
  END,
  updated_at = now()
WHERE id = '{job_id}'::uuid
RETURNING id, current_stage, progress_pct, status;
'''
print(json.dumps({'query': sql}))
" "$JOB_ID" "$STAGE" "$PROGRESS" "$NOTES" "$NOW")

RESULT=$(curl -s -X POST "$API" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d "$SQL")

# Check result
if echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); assert len(d)>0" 2>/dev/null; then
  echo "✓ Job ${JOB_ID}: ${STAGE} @ ${PROGRESS}% — ${NOTES:-no notes}"
else
  echo "✗ Failed to update job ${JOB_ID}" >&2
  echo "$RESULT" >&2
  exit 1
fi
