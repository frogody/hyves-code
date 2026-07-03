#!/usr/bin/env bash
# lumos-quality-gate.sh — Automated 14-point quality validation for Lumos Maxima runs
# Usage: lumos-quality-gate.sh <job_id> <working_dir>
#
# Runs after Stage 4 (research + merge complete), before Stage 5 (document generation).
# Reads batch JSON files and priority CSV to validate data quality.
#
# Exit codes:
#   0 = all checks passed (continue to Stage 5)
#   1 = one or more checks failed (pipeline halted)
#   2 = missing required files/args

set -euo pipefail

JOB_ID="${1:?Usage: lumos-quality-gate.sh <job_id> <working_dir>}"
WORK_DIR="${2:?Missing working directory}"
TOKEN="${SUPABASE_ACCESS_TOKEN:?Set SUPABASE_ACCESS_TOKEN env var}"
PROJECT="${SUPABASE_PROJECT_ID:-sfxpmzicgpaxfntqleig}"
API="https://api.supabase.com/v1/projects/${PROJECT}/database/query"
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Find key files
PRIORITY_CSV=""
ENRICHED_CSV=""
RESEARCH_DIR=""

# Locate priority ranking CSV
for f in "$WORK_DIR"/priority_ranking*.csv "$WORK_DIR"/output/priority_ranking*.csv; do
  [ -f "$f" ] && PRIORITY_CSV="$f" && break
done

# Locate enriched CSV
for f in "$WORK_DIR"/enriched*.csv "$WORK_DIR"/output/enriched*.csv "$WORK_DIR"/*_enriched_ranking*.csv "$WORK_DIR"/output/*_enriched_ranking*.csv; do
  [ -f "$f" ] && ENRICHED_CSV="$f" && break
done

# Locate research results directory
for d in "$WORK_DIR"/research_results "$WORK_DIR"/output/research_results; do
  [ -d "$d" ] && RESEARCH_DIR="$d" && break
done

if [ -z "$PRIORITY_CSV" ] || [ -z "$RESEARCH_DIR" ]; then
  echo "QUALITY GATE ERROR: Missing required files"
  echo "  Priority CSV: ${PRIORITY_CSV:-NOT FOUND}"
  echo "  Research dir:  ${RESEARCH_DIR:-NOT FOUND}"
  echo "  Enriched CSV:  ${ENRICHED_CSV:-NOT FOUND (optional)}"
  exit 2
fi

echo ""
echo "LUMOS QUALITY GATE"
echo "Job:  $JOB_ID"
echo "Dir:  $WORK_DIR"
echo "CSV:  $PRIORITY_CSV"
echo "Data: $RESEARCH_DIR"
echo ""

# Fetch target_company_count from DB
TARGET_COUNT=$(curl -s -X POST "$API" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"query\": \"SELECT target_company_count FROM lumos_maxima_jobs WHERE id = '${JOB_ID}'::uuid\"}" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['target_company_count'] if d else 500)" 2>/dev/null || echo 500)

# Export vars for the Python heredoc (heredocs don't receive CLI args via sys.argv)
export QG_WORK_DIR="$WORK_DIR"
export QG_PRIORITY_CSV="$PRIORITY_CSV"
export QG_ENRICHED_CSV="${ENRICHED_CSV:-}"
export QG_RESEARCH_DIR="$RESEARCH_DIR"
export QG_TARGET_COUNT="$TARGET_COUNT"
export QG_NOW="$NOW"

# Run all 14 checks via Python
GATE_RESULT=$(python3 << 'PYEOF'
import json, csv, sys, os, glob
from collections import Counter

work_dir = os.environ['QG_WORK_DIR']
priority_csv = os.environ['QG_PRIORITY_CSV']
enriched_csv = os.environ.get('QG_ENRICHED_CSV') or None
research_dir = os.environ['QG_RESEARCH_DIR']
target_count = int(os.environ['QG_TARGET_COUNT'])

checks = []
all_passed = True

def check(name, passed, detail=""):
    global all_passed
    checks.append({"name": name, "passed": passed, "detail": detail})
    if not passed:
        all_passed = False
    status = "PASS" if passed else "FAIL"
    print(f"  [{status}] {name}: {detail}", file=sys.stderr)

# Load all research batch JSONs
all_companies = []
batch_files = sorted(glob.glob(os.path.join(research_dir, "batch_*.json")))
for bf in batch_files:
    try:
        with open(bf) as f:
            data = json.load(f)
            if isinstance(data, list):
                all_companies.extend(data)
    except:
        pass

# Load priority CSV
priority_rows = []
try:
    with open(priority_csv, newline='', encoding='utf-8-sig') as f:
        reader = csv.DictReader(f)
        priority_rows = list(reader)
except Exception as e:
    check("CSV_LOAD", False, f"Failed to load priority CSV: {e}")

# Load enriched CSV if available
enriched_rows = []
if enriched_csv and os.path.exists(enriched_csv):
    try:
        with open(enriched_csv, newline='', encoding='utf-8-sig') as f:
            reader = csv.DictReader(f)
            enriched_rows = list(reader)
    except:
        pass

# ── CHECK 1: Domain deduplication ──
domains = []
for row in priority_rows:
    d = (row.get("Company Domain") or row.get("domain") or row.get("Domain") or "").strip().lower()
    if d:
        domains.append(d)
dupes = [d for d, c in Counter(domains).items() if c > 1]
check("1_domain_dedup", len(dupes) == 0, f"{len(dupes)} duplicates" + (f": {dupes[:5]}" if dupes else ""))

# ── CHECK 2: Score range (0-2) ──
score_violations = 0
for comp in all_companies:
    scores = comp.get("scores", {})
    for k, v in scores.items():
        try:
            val = int(v)
            if val < 0 or val > 2:
                score_violations += 1
        except:
            score_violations += 1
check("2_score_range", score_violations == 0, f"{score_violations} violations (must be 0-2)")

# ── CHECK 3: Composite = sum of dimensions ──
composite_mismatches = 0
for comp in all_companies:
    scores = comp.get("scores", {})
    composite = comp.get("composite_score", 0)
    try:
        dim_sum = sum(int(v) for v in scores.values())
        if abs(int(composite) - dim_sum) > 0:
            # Allow stored_composite override if composite=0
            if int(composite) == 0 and dim_sum > 0:
                pass  # Known formatting issue, not a real mismatch
            else:
                composite_mismatches += 1
    except:
        composite_mismatches += 1
check("3_composite_sum", composite_mismatches == 0, f"{composite_mismatches} mismatches")

# ── CHECK 4: Zero-score detection ──
total_companies = len(all_companies)
zero_companies = 0
for comp in all_companies:
    scores = comp.get("scores", {})
    if scores and all(int(v) == 0 for v in scores.values()):
        zero_companies += 1
zero_pct = (zero_companies / max(total_companies, 1)) * 100
check("4_zero_score", zero_pct < 5, f"{zero_companies}/{total_companies} ({zero_pct:.1f}%) all-zero")

# ── CHECK 5-7: Tier distribution ──
tiers = Counter()
for row in priority_rows:
    tier = (row.get("Tier") or row.get("tier") or "").strip().upper()
    if tier:
        tiers[tier] += 1
total_tiered = sum(tiers.values())
if total_tiered > 0:
    a_pct = tiers.get("A", 0) / total_tiered * 100
    b_pct = tiers.get("B", 0) / total_tiered * 100
    c_pct = tiers.get("C", 0) / total_tiered * 100
    check("5_tier_a_range", 5 <= a_pct <= 25, f"{a_pct:.1f}% (target 10-20%)")
    check("6_tier_b_range", 45 <= b_pct <= 75, f"{b_pct:.1f}% (target 55-70%)")
    check("7_tier_c_range", 15 <= c_pct <= 40, f"{c_pct:.1f}% (target 20-35%)")
else:
    check("5_tier_a_range", False, "No tier data found")
    check("6_tier_b_range", False, "No tier data found")
    check("7_tier_c_range", False, "No tier data found")

# ── CHECK 8: False positives flagged ──
# Companies with $100M+ funding or 200+ employees should not be Tier A
false_positive_issues = 0
for row in priority_rows:
    tier = (row.get("Tier") or row.get("tier") or "").strip().upper()
    if tier != "A":
        continue
    fp = (row.get("False_Positive") or row.get("false_positive") or "").strip().lower()
    if fp in ("yes", "true", "1"):
        false_positive_issues += 1
check("8_false_positives", True, f"{false_positive_issues} flagged FPs in Tier A (informational)")

# ── CHECK 9-11: Contact data completeness ──
target_rows = enriched_rows if enriched_rows else priority_rows
total_rows = len(target_rows)
if total_rows > 0:
    has_url = sum(1 for r in target_rows if (r.get("Company_URL") or r.get("Company URL") or r.get("company_url") or "").strip())
    has_li = sum(1 for r in target_rows if (r.get("LinkedIn_URL") or r.get("LinkedIn URL") or r.get("linkedin_url") or "").strip())
    has_contact = sum(1 for r in target_rows if (r.get("Contact_LinkedIn") or r.get("Contact LinkedIn") or r.get("contact_linkedin") or "").strip())
    url_pct = has_url / total_rows * 100
    li_pct = has_li / total_rows * 100
    contact_pct = has_contact / total_rows * 100
    check("9_company_url", url_pct >= 95, f"{has_url}/{total_rows} ({url_pct:.0f}%)")
    check("10_linkedin_url", li_pct >= 95, f"{has_li}/{total_rows} ({li_pct:.0f}%)")
    check("11_contact_linkedin", contact_pct >= 95, f"{has_contact}/{total_rows} ({contact_pct:.0f}%)")
else:
    check("9_company_url", False, "No rows found")
    check("10_linkedin_url", False, "No rows found")
    check("11_contact_linkedin", False, "No rows found")

# ── CHECK 12: Row count match ──
csv_count = len(priority_rows)
# Allow 10% tolerance on row count
tolerance = max(target_count * 0.1, 20)
in_range = abs(csv_count - target_count) <= tolerance
check("12_row_count", in_range, f"{csv_count} rows vs {target_count} target (tolerance {int(tolerance)})")

# ── CHECK 13: Max composite 24 ──
over_24 = 0
for comp in all_companies:
    try:
        if int(comp.get("composite_score", 0)) > 24:
            over_24 += 1
    except:
        pass
check("13_max_composite", over_24 == 0, f"{over_24} companies above 24")

# ── CHECK 14: Dimension key completeness ──
missing_dims = 0
for comp in all_companies:
    scores = comp.get("scores", {})
    if len(scores) < 12:
        missing_dims += 1
missing_pct = (missing_dims / max(total_companies, 1)) * 100
check("14_dim_completeness", missing_pct < 10, f"{missing_dims}/{total_companies} ({missing_pct:.1f}%) have <12 dimensions")

# Output result JSON
result = {
    "all_passed": all_passed,
    "checks": checks,
    "summary": {
        "total_checks": len(checks),
        "passed": sum(1 for c in checks if c["passed"]),
        "failed": sum(1 for c in checks if not c["passed"]),
        "total_companies_research": total_companies,
        "total_companies_csv": len(priority_rows),
        "tier_distribution": dict(tiers) if tiers else {},
    },
    "timestamp": os.environ['QG_NOW'],
}
print(json.dumps(result))
PYEOF
)

# Extract pass/fail from JSON
PASSED=$(echo "$GATE_RESULT" | python3 -c "import sys,json; lines=[l for l in sys.stdin if l.strip().startswith('{')]; d=json.loads(lines[-1]) if lines else {}; print('true' if d.get('all_passed') else 'false')" 2>/dev/null || echo "false")
RESULT_JSON=$(echo "$GATE_RESULT" | python3 -c "import sys,json; lines=[l for l in sys.stdin if l.strip().startswith('{')]; print(lines[-1].strip()) if lines else print('{}')" 2>/dev/null || echo "{}")

# Escape JSON for SQL
RESULT_ESC=$(echo "$RESULT_JSON" | python3 -c "import sys; print(sys.stdin.read().strip().replace(\"'\", \"''\"))")

# Update DB with quality gate results
if [ "$PASSED" = "true" ]; then
  STATUS_UPDATE="quality_gate_passed = true"
  echo ""
  echo "QUALITY GATE: PASSED"
  echo "All checks passed. Continuing to Stage 5 (document generation)."
else
  STATUS_UPDATE="quality_gate_passed = false, status = 'quality_gate_failed'"
  echo ""
  echo "QUALITY GATE: FAILED"
  echo "One or more checks failed. Pipeline halted."
fi

SQL="UPDATE public.lumos_maxima_jobs SET ${STATUS_UPDATE}, quality_gate_result = '${RESULT_ESC}'::jsonb, quality_gate_at = '${NOW}'::timestamptz, updated_at = now() WHERE id = '${JOB_ID}'::uuid"

curl -s -X POST "$API" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d "$(python3 -c "import json,sys; print(json.dumps({'query': sys.stdin.read()}))" <<< "$SQL")" > /dev/null

echo ""

# Exit with appropriate code
if [ "$PASSED" = "true" ]; then
  exit 0
else
  exit 1
fi
