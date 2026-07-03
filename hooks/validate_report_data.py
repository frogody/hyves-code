#!/usr/bin/env python3
"""Validate report_data.json against the frontend schema expected by GrowthLumosMaximaReport.jsx."""
import json, sys

REQUIRED_FIELDS = {
    'meta': dict, 'headline': list, 'verticals': list, 'tiers': dict,
    'score_distribution': list, 'vertical_scorecards': list,
    'top_differentiators': list, 'narrative_patterns': list,
    'revenue_pipeline': dict, 'campaign_segments': list,
    'geographic': list, 'false_positives': list, 'top_25': list,
    'competitors': list, 'outreach_waves': list, 'key_insights': list,
    'executive_metrics': list, 'top_actions': list, 'research_stats': list,
    'priority_20': list, 'outreach_campaigns': list,
    'urgency_signals': dict, 'competitive_landscape': dict,
    'contact_analysis': dict, 'dimension_correlations': list,
}

def validate(path):
    with open(path) as f:
        data = json.load(f)

    filled = 0
    empty = 0
    errors = []

    for field, expected_type in REQUIRED_FIELDS.items():
        val = data.get(field)
        if val is None:
            errors.append(f"  MISSING: {field}")
            empty += 1
        elif not isinstance(val, expected_type):
            errors.append(f"  WRONG TYPE: {field} — expected {expected_type.__name__}, got {type(val).__name__}")
            empty += 1
        elif isinstance(val, (list, dict)) and len(val) == 0:
            errors.append(f"  EMPTY: {field} (present but no data)")
            empty += 1
        else:
            filled += 1

    total = len(REQUIRED_FIELDS)
    pct = round(filled / total * 100)
    print(f"\n{'='*50}")
    print(f" Report Data Validation: {filled}/{total} sections filled ({pct}%)")
    print(f"{'='*50}")
    if errors:
        print(f"\n Issues ({len(errors)}):")
        for e in errors:
            print(e)
    else:
        print("\n All sections have data!")
    print()
    return len(errors) == 0

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Usage: validate_report_data.py <report_data.json>")
        sys.exit(1)
    ok = validate(sys.argv[1])
    sys.exit(0 if ok else 1)
