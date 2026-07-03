#!/usr/bin/env bash
# lumos-upload.sh — Upload a deliverable to Supabase Storage and update job
# Usage: lumos-upload.sh <job_id> <company_id> <local_file> <output_name> <display_name> <format>
#
# Examples:
#   lumos-upload.sh abc-123 comp-456 ./priority_ranking.csv priority_ranking.csv "Priority Ranking" csv
#   lumos-upload.sh abc-123 comp-456 ./report.pdf market_intel_report.pdf "Market Intelligence Report" pdf

set -euo pipefail

JOB_ID="${1:?Usage: lumos-upload.sh <job_id> <company_id> <local_file> <output_name> <display_name> <format>}"
COMPANY_ID="${2:?Missing company_id}"
LOCAL_FILE="${3:?Missing local_file}"
OUTPUT_NAME="${4:?Missing output_name}"
DISPLAY_NAME="${5:?Missing display_name}"
FORMAT="${6:?Missing format (csv/pdf/md/json/txt)}"

TOKEN="${SUPABASE_ACCESS_TOKEN:?Set SUPABASE_ACCESS_TOKEN env var}"
PROJECT="${SUPABASE_PROJECT_ID:-sfxpmzicgpaxfntqleig}"
SUPABASE_URL="https://${PROJECT}.supabase.co"
SERVICE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
if [ -z "$SERVICE_KEY" ] && [ -f /tmp/supabase_service_key.txt ]; then
  SERVICE_KEY=$(cat /tmp/supabase_service_key.txt)
fi
if [ -z "$SERVICE_KEY" ]; then
  # Fetch from Management API as last resort
  SERVICE_KEY=$(curl -s "https://api.supabase.com/v1/projects/${PROJECT}/api-keys" \
    -H "Authorization: Bearer ${TOKEN}" | python3 -c "import json,sys; keys=json.load(sys.stdin); print([k['api_key'] for k in keys if k['name']=='service_role'][0])" 2>/dev/null || true)
fi
if [ -z "$SERVICE_KEY" ]; then
  echo "✗ No service role key available. Set SUPABASE_SERVICE_ROLE_KEY or populate /tmp/supabase_service_key.txt" >&2
  exit 1
fi
API="https://api.supabase.com/v1/projects/${PROJECT}/database/query"

# Validate file exists
if [ ! -f "$LOCAL_FILE" ]; then
  echo "✗ File not found: $LOCAL_FILE" >&2
  exit 1
fi

STORAGE_PATH="${COMPANY_ID}/${JOB_ID}/output/${OUTPUT_NAME}"
SIZE_KB=$(( $(stat -f%z "$LOCAL_FILE" 2>/dev/null || stat -c%s "$LOCAL_FILE" 2>/dev/null) / 1024 ))
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Determine MIME type
case "$FORMAT" in
  csv)  MIME="text/csv" ;;
  pdf)  MIME="application/pdf" ;;
  md)   MIME="text/markdown" ;;
  json) MIME="application/json" ;;
  txt)  MIME="text/plain" ;;
  *)    MIME="application/octet-stream" ;;
esac

# Get row count for CSVs
ROW_COUNT=""
COL_COUNT=""
if [ "$FORMAT" = "csv" ]; then
  ROW_COUNT=$(tail -n +2 "$LOCAL_FILE" | wc -l | tr -d ' ')
  COL_COUNT=$(head -1 "$LOCAL_FILE" | awk -F',' '{print NF}')
fi

# Upload to Supabase Storage (with retries)
echo "↑ Uploading ${OUTPUT_NAME} (${SIZE_KB} KB)..."

MAX_RETRIES=3
RETRY_DELAY=5
UPLOAD_RESULT=""

for ATTEMPT in $(seq 1 $MAX_RETRIES); do
  UPLOAD_RESULT=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time 120 \
    -X POST "${SUPABASE_URL}/storage/v1/object/lumos-maxima/${STORAGE_PATH}" \
    -H "Authorization: Bearer ${SERVICE_KEY:-$TOKEN}" \
    -H "Content-Type: ${MIME}" \
    -H "x-upsert: true" \
    --data-binary @"$LOCAL_FILE" 2>/dev/null || echo "000")

  if [ "$UPLOAD_RESULT" -ge 200 ] && [ "$UPLOAD_RESULT" -lt 300 ]; then
    break
  fi

  if [ "$ATTEMPT" -lt "$MAX_RETRIES" ]; then
    echo "  ⚠ Attempt $ATTEMPT failed (HTTP ${UPLOAD_RESULT}), retrying in ${RETRY_DELAY}s..."
    sleep $RETRY_DELAY
    RETRY_DELAY=$((RETRY_DELAY * 2))
  fi
done

if [ "$UPLOAD_RESULT" -lt 200 ] || [ "$UPLOAD_RESULT" -ge 300 ]; then
  echo "✗ Upload failed after ${MAX_RETRIES} attempts (HTTP ${UPLOAD_RESULT})" >&2
  exit 1
fi

# Build deliverable JSON entry
DELIV_JSON="{\"name\": \"${DISPLAY_NAME}\", \"filename\": \"${OUTPUT_NAME}\", \"path\": \"${STORAGE_PATH}\", \"format\": \"${FORMAT}\", \"size_kb\": ${SIZE_KB}, \"uploaded_at\": \"${NOW}\""
[ -n "$ROW_COUNT" ] && DELIV_JSON="${DELIV_JSON}, \"row_count\": ${ROW_COUNT}, \"col_count\": ${COL_COUNT}"
DELIV_JSON="${DELIV_JSON}}"

# Update job deliverables array
SQL="
UPDATE public.lumos_maxima_jobs
SET deliverables = COALESCE(deliverables, '[]'::jsonb) || '${DELIV_JSON}'::jsonb,
    updated_at = now()
WHERE id = '${JOB_ID}'::uuid
RETURNING id, jsonb_array_length(deliverables) as deliverable_count;
"

RESULT=$(curl -s -X POST "$API" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d "$(python3 -c "import json,sys; print(json.dumps({'query': sys.stdin.read()}))" <<< "$SQL")")

echo "✓ Uploaded ${DISPLAY_NAME} → lumos-maxima/${STORAGE_PATH} (${SIZE_KB} KB)"
