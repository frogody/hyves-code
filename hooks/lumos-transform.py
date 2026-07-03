#!/usr/bin/env python3
"""
lumos-transform.py — Convert pipeline output JSONs to report viewer format.

Usage:
  lumos-transform.py <commercial_analysis.json> <strategic_analysis.json> <output.json> [--priority-ranking <csv>]

Maps the raw pipeline output fields to the unified report_data.json format
expected by GrowthLumosMaximaReport.jsx
"""

import json
import sys
import csv
import os
from pathlib import Path


def safe_get(obj, *keys, default=None):
    """Safely navigate nested dicts."""
    current = obj
    for key in keys:
        if isinstance(current, dict):
            current = current.get(key)
        else:
            return default
        if current is None:
            return default
    return current


def transform_verticals(metadata):
    """metadata.verticals → [{ name, count }]"""
    verts = safe_get(metadata, 'verticals', default={})
    if isinstance(verts, dict):
        return [{'name': k, 'count': v} for k, v in verts.items()]
    return []


def transform_tiers(metadata):
    """metadata.tier_distribution → { A: { count, pct }, B: ..., C: ... }"""
    dist = safe_get(metadata, 'tier_distribution', default={})
    if not isinstance(dist, dict):
        return {'A': {'count': 0, 'pct': 0}, 'B': {'count': 0, 'pct': 0}, 'C': {'count': 0, 'pct': 0}}
    total = sum(v for v in dist.values() if isinstance(v, (int, float)))
    result = {}
    for tier in ['A', 'B', 'C', 'D']:
        count = dist.get(tier, 0)
        pct = round((count / total * 100), 1) if total > 0 else 0
        result[tier] = {'count': count, 'pct': pct}
    return result


def transform_score_distribution(section1, csv_path=None, tier_thresholds=None):
    """section_1_sweet_spot_profile.score_distribution → [{ score, count, tier }]"""
    # Best option: build actual distribution from CSV
    if csv_path and os.path.exists(csv_path):
        try:
            score_counts = {}
            with open(csv_path, 'r', encoding='utf-8-sig') as f:
                reader = csv.DictReader(f)
                for row in reader:
                    score = int(row.get('Composite_Score', row.get('composite_score', row.get('Score', 0))))
                    score_counts[score] = score_counts.get(score, 0) + 1
            if score_counts:
                # Determine tier thresholds
                a_min = 19  # default
                b_min = 13
                c_min = 7
                if tier_thresholds:
                    # Parse from "19-24" format
                    a_range = tier_thresholds.get('A', '')
                    if isinstance(a_range, str) and '-' in a_range:
                        a_min = int(a_range.split('-')[0])
                    b_range = tier_thresholds.get('B', '')
                    if isinstance(b_range, str) and '-' in b_range:
                        b_min = int(b_range.split('-')[0])
                    c_range = tier_thresholds.get('C', '')
                    if isinstance(c_range, str) and '-' in c_range:
                        c_min = int(c_range.split('-')[0])
                result = []
                for score in sorted(score_counts.keys(), reverse=True):
                    tier = 'A' if score >= a_min else ('B' if score >= b_min else ('C' if score >= c_min else 'D'))
                    result.append({'score': score, 'count': score_counts[score], 'tier': tier})
                return result
        except Exception:
            pass

    sd = safe_get(section1, 'score_distribution', default={})
    if not isinstance(sd, dict):
        return []

    # The pipeline gives aggregate counts like score_18_plus, score_16_plus, etc.
    # We need to derive individual score bins
    # If there's a detailed breakdown, use it
    if 'bins' in sd:
        return [{'score': b['score'], 'count': b['count'],
                 'tier': 'A' if b['score'] >= 18 else ('B' if b['score'] >= 13 else 'C')}
                for b in sd['bins']]

    # Otherwise derive from aggregate data
    max_score = sd.get('max', 24)
    min_score = sd.get('min', 10)
    score_20 = sd.get('score_20', 0)
    score_18_plus = sd.get('score_18_plus', 0)
    score_16_plus = sd.get('score_16_plus', 0)
    score_15_plus = sd.get('score_15_plus', 0)

    result = []
    if score_20 > 0:
        result.append({'score': 20, 'count': score_20, 'tier': 'A'})
    score_18_19 = score_18_plus - score_20
    if score_18_19 > 0:
        # Split roughly between 18 and 19
        s19 = score_18_19 // 2
        s18 = score_18_19 - s19
        if s19 > 0:
            result.append({'score': 19, 'count': s19, 'tier': 'A'})
        if s18 > 0:
            result.append({'score': 18, 'count': s18, 'tier': 'A'})
    score_16_17 = score_16_plus - score_18_plus
    if score_16_17 > 0:
        s17 = score_16_17 // 2
        s16 = score_16_17 - s17
        if s17 > 0:
            result.append({'score': 17, 'count': s17, 'tier': 'B'})
        if s16 > 0:
            result.append({'score': 16, 'count': s16, 'tier': 'B'})
    score_15 = score_15_plus - score_16_plus
    if score_15 > 0:
        result.append({'score': 15, 'count': score_15, 'tier': 'B'})
    # Below 15 — estimate remaining as B/C
    dataset_size = safe_get(section1, '..', default={}).get('dataset_size', 500)
    remaining = max(0, dataset_size - score_15_plus) if isinstance(dataset_size, int) else 0
    if remaining > 0:
        # Rough split: 14, 13 as B; 12, 11, 10 as C
        per_score = remaining // 5 if remaining > 5 else remaining
        for s in range(14, 9, -1):
            if remaining <= 0:
                break
            count = min(per_score, remaining)
            result.append({'score': s, 'count': count, 'tier': 'B' if s >= 13 else 'C'})
            remaining -= count

    return sorted(result, key=lambda x: -x['score'])


def transform_top25(section1, priority_csv=None):
    """Combine top10_companies + score_18_plus_companies → top_25"""
    top10 = safe_get(section1, 'top10_companies', default=[])
    score18 = safe_get(section1, 'score_18_plus_companies', default=[])

    # Merge, deduplicate by name
    seen = set()
    result = []
    for company in (top10 + score18):
        name = company.get('name', '')
        if name in seen:
            continue
        seen.add(name)
        result.append({
            'rank': company.get('rank', len(result) + 1),
            'company': name,
            'vertical': company.get('vertical', ''),
            'score': company.get('score', 0),
            'contact': company.get('contact', ''),
            'title': company.get('title', ''),
        })
    return result[:25]


def transform_top_differentiators(section1, commercial=None):
    """dimension_profiles.*.top10_vs_rank11_50 → [{ dimension, delta }]"""
    profiles = safe_get(section1, 'dimension_profiles', default={})
    result = []
    seen = set()

    for vertical_key, vertical_data in profiles.items():
        comparisons = safe_get(vertical_data, 'top10_vs_rank11_50', default={})
        if isinstance(comparisons, dict):
            for dim_name, data in comparisons.items():
                if dim_name in seen:
                    continue
                seen.add(dim_name)
                delta = data.get('delta', 0) if isinstance(data, dict) else 0
                result.append({'dimension': dim_name, 'delta': round(delta, 2)})

    # Fallback: from commercial dimension_correlations.tier_a_lift
    if not result and commercial:
        tier_a_lift = safe_get(commercial, 'dimension_correlations', 'tier_a_lift', default={})
        for dim_name, data in tier_a_lift.items():
            if isinstance(data, dict):
                result.append({
                    'dimension': data.get('label', dim_name),
                    'delta': round(data.get('lift', 0), 2)
                })

    # Fallback: from tier_a_predictors in overall
    if not result and commercial:
        predictors = safe_get(commercial, 'dimension_correlations', 'overall', 'tier_a_predictors', default=[])
        for p in predictors:
            if isinstance(p, dict):
                result.append({
                    'dimension': p.get('dim', ''),
                    'delta': round(p.get('lift', 0), 2)
                })

    return sorted(result, key=lambda x: -x['delta'])


def transform_false_positives(section4):
    """section_4_risk_assessment.false_positive_tier_a_candidates → false_positives"""
    fps = safe_get(section4, 'false_positive_tier_a_candidates', default=[])
    if not fps:
        fps = safe_get(section4, 'false_positives', default=[])
    return [{
        'company': fp.get('name', ''),
        'score': fp.get('score', 0),
        'issue': fp.get('explanation', fp.get('reason', '')),
        'rank': fp.get('rank', 0),
        'zero_dims': fp.get('zero_dimensions', fp.get('zero_dims', 0)),
        'risk': fp.get('risk_score', fp.get('risk', 'high' if fp.get('recommended_action') == 'downgrade' else 'medium')),
    } for fp in fps]


def transform_campaign_segments(section5):
    """section_5_campaign_clustering.segments → campaign_segments"""
    segments = safe_get(section5, 'segments', default=[])
    return [{
        'id': seg.get('segment_id', seg.get('id', i + 1)),
        'name': seg.get('segment_name', seg.get('name', '')),
        'vertical': seg.get('vertical_focus', seg.get('defining_characteristics', '')[:50]),
        'size': seg.get('count', seg.get('company_count', 0)),
        'avg': seg.get('avg_score', 0),
        'tier_a': seg.get('tier_distribution', {}).get('A', 0) if isinstance(seg.get('tier_distribution'), dict) else 0,
        'product': seg.get('recommended_product', ''),
    } for i, seg in enumerate(segments)]


def extract_int(val, default=0):
    """Extract integer from various formats (int, string with EUR/numbers, dict with count)."""
    if isinstance(val, (int, float)):
        return int(val)
    if isinstance(val, dict):
        return val.get('count', val.get('target_count', default))
    if isinstance(val, str):
        import re
        nums = re.findall(r'[\d,]+', val.replace(',', ''))
        return int(nums[0]) if nums else default
    return default


def transform_revenue_pipeline(section6):
    """section_6_revenue_potential → revenue_pipeline"""
    if not section6:
        return {'products': [], 'year1': [], 'summary': []}

    ap = safe_get(section6, 'addressable_pipeline', default={})

    # Format C (Accelr): by_tier + year_1_revenue + pricing at top level
    by_tier = safe_get(section6, 'by_tier', default=None)
    year1_revenue = safe_get(section6, 'year_1_revenue', default=None)
    pricing = safe_get(section6, 'pricing', default={})

    if by_tier and year1_revenue:
        # Use the detailed Accelr format
        moderate = year1_revenue.get('moderate', {})
        conservative = year1_revenue.get('conservative', {})
        optimistic = year1_revenue.get('optimistic', {})

        scan_count = moderate.get('scan_count', 0)
        bouw_count = moderate.get('bouw_count', 0)
        motor_count = moderate.get('motor_count', 0)

        products = [
            {
                'name': 'De Scan',
                'candidates': scan_count,
                'price': f'€{pricing.get("de_scan", 3500):,}',
                'profile': 'Entry product — drives awareness, qualifies buyers for upgrade',
            },
            {
                'name': 'De Bouw',
                'candidates': bouw_count,
                'price': f'€{pricing.get("de_bouw_low", 7500):,}–€{pricing.get("de_bouw_high", 17500):,}',
                'profile': 'Highest single-contract value; avg €12,500',
            },
            {
                'name': 'De Motor',
                'candidates': motor_count,
                'price': f'€{pricing.get("de_motor_monthly_avg", 3750):,}/mo',
                'profile': 'Recurring fractional HoS — compounding revenue asset',
            },
        ]

        year1 = [
            {'product': 'De Scan', 'conversion': '—', 'deals': str(scan_count),
             'revenue': f'€{moderate.get("scan_revenue", 0):,}'},
            {'product': 'De Bouw', 'conversion': '—', 'deals': str(bouw_count),
             'revenue': f'€{moderate.get("bouw_revenue", 0):,}'},
            {'product': 'De Motor', 'conversion': '—', 'deals': f'{motor_count} × 12mo',
             'revenue': f'€{moderate.get("motor_revenue", 0):,}'},
        ]

        mod_total = moderate.get('value', 0)
        con_total = conservative.get('value', 0)
        opt_total = optimistic.get('value', 0)

        upsell = section6.get('upsell_trajectory', '—')
        if isinstance(upsell, dict):
            upsell = upsell.get('summary', upsell.get('description', '—'))
        # Build strategic insights for upsell
        insights = safe_get(section6, 'strategic_revenue_insights', default=[])
        upsell_str = str(upsell)[:50] if isinstance(upsell, str) and upsell != '—' else (
            insights[2][:50] if len(insights) > 2 else '—')

        summary = [
            {'value': f'€{mod_total:,}', 'label': 'Moderate Pipeline'},
            {'value': f'€{con_total:,}–€{opt_total:,}', 'label': 'Range (Con–Opt)'},
            {'value': str(scan_count + bouw_count + motor_count), 'label': 'Projected Deals'},
            {'value': upsell_str, 'label': 'Year 2 Compounding'},
        ]

        return {'products': products, 'year1': year1, 'summary': summary}

    # Format A/B: addressable_pipeline with de_scan_at_3500 etc.
    scan = (safe_get(ap, 'de_scan_at_3500', default={})
            or safe_get(ap, 'de_scan_candidates', default={}))
    bouw = (safe_get(ap, 'de_bouw_at_15000', default={})
            or safe_get(ap, 'de_bouw_candidates', default={}))
    motor = (safe_get(ap, 'de_motor_at_5000_monthly', default={})
             or safe_get(ap, 'de_motor_fractional_hos_candidates', default={}))

    scan_count = extract_int(scan.get('count', scan.get('target_count', 0)))
    bouw_count = extract_int(bouw.get('count', bouw.get('target_count', 0)))
    motor_count = extract_int(motor.get('count', motor.get('target_count', 0)))

    products = [
        {
            'name': 'De Scan',
            'candidates': scan_count,
            'price': scan.get('unit_price', '€3,500'),
            'profile': scan.get('description', 'Tier B/C — need diagnosis before treatment'),
        },
        {
            'name': 'De Bouw',
            'candidates': bouw_count,
            'price': bouw.get('unit_price', '€7,500-17,500'),
            'profile': bouw.get('description', 'Tier A / high B — ready for buildout'),
        },
        {
            'name': 'De Motor',
            'candidates': motor_count,
            'price': motor.get('unit_price', '€2,500-5,000/mo'),
            'profile': motor.get('description', 'Top Tier A — ongoing fractional HoS'),
        },
    ]

    # Year 1 estimates
    scan_deals = max(1, scan_count * 12 // 100) if scan_count else 0
    bouw_deals = max(1, bouw_count * 8 // 100) if bouw_count else 0
    motor_deals = max(1, motor_count * 10 // 100) if motor_count else 0

    year1 = [
        {'product': 'De Scan', 'conversion': '12%', 'deals': str(scan_deals), 'revenue': f'€{scan_deals * 3500:,}'},
        {'product': 'De Bouw', 'conversion': '8%', 'deals': str(bouw_deals), 'revenue': f'€{bouw_deals * 7500:,} – €{bouw_deals * 17500:,}'},
        {'product': 'De Motor', 'conversion': '10%', 'deals': f'{motor_deals} deals × 12mo', 'revenue': f'€{motor_deals * 2500 * 12:,} – €{motor_deals * 5000 * 12:,}'},
    ]

    # Extract pipeline value (may be dict or int)
    year1_raw = section6.get('realistic_year1_pipeline', {})
    if isinstance(year1_raw, dict):
        total_str = year1_raw.get('total_year1_midpoint', year1_raw.get('midpoint', ''))
        if isinstance(total_str, str) and 'EUR' in total_str.upper():
            pipeline_str = total_str.replace('EUR ', '€')
        else:
            midpoint = scan_deals * 3500 + bouw_deals * 12500 + motor_deals * 3750 * 12
            pipeline_str = f'€{midpoint:,}'
    elif isinstance(year1_raw, (int, float)):
        pipeline_str = f'€{int(year1_raw):,}'
    else:
        midpoint = scan_deals * 3500 + bouw_deals * 12500 + motor_deals * 3750 * 12
        pipeline_str = f'€{midpoint:,}'

    upsell = section6.get('upsell_trajectory', '—')
    if isinstance(upsell, dict):
        upsell = upsell.get('summary', upsell.get('description', '—'))

    summary = [
        {'value': pipeline_str, 'label': 'Midpoint Pipeline'},
        {'value': str(scan_deals + bouw_deals + motor_deals), 'label': 'Projected Deals'},
        {'value': str(upsell)[:50] if isinstance(upsell, str) else '—', 'label': 'Year 2 Upsell'},
        {'value': str(motor_count), 'label': 'De Motor Candidates'},
    ]

    return {'products': products, 'year1': year1, 'summary': summary}


def transform_geographic(commercial):
    """geographic_clusters → [{ city, count }]"""
    geo = safe_get(commercial, 'geographic_clusters', default={})
    cities = safe_get(geo, 'top_cities_by_tier_a', default=None)
    # Fallback: try various key names
    if not cities:
        cities = safe_get(geo, 'top_cities_by_total', default=None)
    if not cities:
        cities = safe_get(geo, 'top_cities', default=None)
    if not cities:
        cities = safe_get(geo, 'top_20_cities', default=None)
    if not cities:
        # Try regional_analysis which may contain city-level data
        regional = safe_get(geo, 'regional_analysis', default=[])
        if isinstance(regional, list) and regional:
            cities = [{'city': r.get('region', r.get('city', '')),
                       'count': r.get('company_count', r.get('count', 0))}
                      for r in regional]
    if not isinstance(cities, list):
        cities = []
    return [{'city': c.get('city', c.get('name', '')),
             'count': c.get('tier_a_count', c.get('tier_a', c.get('total_companies', c.get('total', c.get('company_count', c.get('count', 0))))))}
            for c in cities]


def transform_narrative_patterns(commercial):
    """narrative_patterns → [{ pattern, tier_a_pct, count }]"""
    patterns = safe_get(commercial, 'narrative_patterns', default=[])
    # Fallback: check if it's a dict with a 'patterns' key
    if isinstance(patterns, dict):
        patterns = patterns.get('patterns', [])
    if not isinstance(patterns, list):
        patterns = []
    return [{
        'pattern': p.get('pattern', p.get('name', '')),
        'tier_a_pct': p.get('tier_a_concentration', p.get('tier_a_pct', 0)),
        'count': p.get('count', 0),
    } for p in patterns]


def transform_outreach_waves(tiers):
    """Generate standard 5-wave outreach plan from tier distribution."""
    tier_a = tiers.get('A', {}).get('count', 0)
    tier_b = tiers.get('B', {}).get('count', 0)
    tier_c = tiers.get('C', {}).get('count', 0)

    return [
        {'wave': 1, 'timing': 'Week 1-2', 'target': 'Quick Wins (top 15)', 'volume': '15', 'approach': 'Hyper-personalized', 'expected': '15-25% reply'},
        {'wave': 2, 'timing': 'Week 3-4', 'target': 'Remaining Tier A', 'volume': f'~{max(0, tier_a - 15)}', 'approach': 'Semi-personalized', 'expected': '10-15% reply'},
        {'wave': 3, 'timing': 'Week 5-8', 'target': 'Top Tier B (15+)', 'volume': f'~{tier_b // 2}', 'approach': 'Template + detail', 'expected': '5-10% reply'},
        {'wave': 4, 'timing': 'Week 9-16', 'target': 'Remaining Tier B', 'volume': f'~{tier_b - tier_b // 2}', 'approach': 'Scaled + triggers', 'expected': '3-7% reply'},
        {'wave': 5, 'timing': 'Ongoing', 'target': 'Tier C + new', 'volume': f'{tier_c}+', 'approach': 'Nurture + triggers', 'expected': '2-5% reply'},
    ]


def transform_headline(metadata, tiers, section6):
    """Build headline stats cards."""
    verts = safe_get(metadata, 'verticals', default={})
    dataset_size = metadata.get('dataset_size', metadata.get('total_companies', 500))
    tier_a = tiers.get('A', {}).get('count', 0)
    year1_raw = safe_get(section6, 'realistic_year1_pipeline', default=None)
    if not year1_raw:
        # Accelr format
        mod_val = safe_get(section6, 'year_1_revenue', 'moderate', 'value', default=None)
        if mod_val:
            pipeline_str = f"€{int(mod_val):,}"
        else:
            pipeline_str = '—'
    elif isinstance(year1_raw, dict):
        pipeline_str = year1_raw.get('total_year1_midpoint', '—')
        if isinstance(pipeline_str, str) and 'EUR' in pipeline_str.upper():
            pipeline_str = pipeline_str.replace('EUR ', '€')
        elif pipeline_str == '—':
            pipeline_str = '—'
    elif isinstance(year1_raw, (int, float)) and year1_raw:
        pipeline_str = f"€{int(year1_raw):,}"
    else:
        pipeline_str = '—'
    vert_count = len(verts)

    return [
        {'value': str(sum(verts.values()) if isinstance(verts, dict) else 0), 'label': 'Researched\nCompanies', 'color': '#4F7DF3'},
        {'value': str(dataset_size), 'label': 'Ranked\n& Scored', 'color': '#6366F1'},
        {'value': str(tier_a), 'label': 'Tier A\nTargets', 'color': '#22C55E'},
        {'value': pipeline_str, 'label': 'Pipeline\n(Midpoint)', 'color': '#F59E0B'},
        {'value': '12', 'label': 'Research\nDimensions', 'color': '#8B5CF6'},
        {'value': str(vert_count), 'label': 'Focus\nVerticals', 'color': '#EC4899'},
    ]


def transform_vertical_scorecards(metadata, section1):
    """Build vertical scorecards from metadata + section 1 data."""
    verts = safe_get(metadata, 'verticals', default={})
    tier_a_verts = safe_get(section1, 'tier_a_verticals', default={})
    profiles = safe_get(section1, 'dimension_profiles', default={})

    # Build top score + company per vertical from score_18_plus_companies and top10
    top10 = safe_get(section1, 'top10_companies', default=[])
    s18 = safe_get(section1, 'score_18_plus_companies', default=[])
    vert_tops = {}
    for c in (top10 + s18):
        v = c.get('vertical', '')
        score = c.get('score', 0)
        if v not in vert_tops or score > vert_tops[v][0]:
            vert_tops[v] = (score, c.get('name', ''))

    result = []
    for name, count in verts.items():
        tier_a = tier_a_verts.get(name, 0)
        # Look for averages in dimension profiles — handle key variants
        key = name.lower().replace(' ', '_')
        profile = safe_get(profiles, key, default={})
        # Try multiple key names for the averages dict
        avgs = (profile.get('top10_averages')
                or profile.get('top_in_top10_averages')
                or {})
        # Fallback to all_N_averages if top averages empty
        if not avgs:
            for pk, pv in profile.items():
                if pk.startswith('all_') and pk.endswith('_averages') and isinstance(pv, dict) and pv:
                    avgs = pv
                    break
        if isinstance(avgs, dict) and avgs:
            avg_score = round(sum(v for v in avgs.values() if isinstance(v, (int, float))) / len(avgs), 1)
        else:
            avg_score = 0

        top_score, top_company = vert_tops.get(name, (0, ''))

        result.append({
            'name': name,
            'count': count,
            'tier_a': tier_a,
            'tier_b': 0,
            'tier_c': 0,
            'avg': avg_score,
            'top': top_score,
            'top_company': top_company,
        })
    return result


def transform_executive_metrics(metadata, section6, section4):
    """Build executive metrics array."""
    dataset_size = metadata.get('dataset_size', metadata.get('total_companies', 500))
    tier_dist = safe_get(metadata, 'tier_distribution', default={})
    tier_a = tier_dist.get('A', 0)
    fp_count = safe_get(section4, 'false_positive_count', default=0)
    if not fp_count:
        fps = safe_get(section4, 'false_positive_tier_a_candidates', default=[])
        fp_count = len(fps)

    year1_raw = safe_get(section6, 'realistic_year1_pipeline', default=None)
    if not year1_raw:
        # Accelr format: year_1_revenue.moderate.value
        mod_val = safe_get(section6, 'year_1_revenue', 'moderate', 'value', default=None)
        if mod_val:
            year1_str = f'€{int(mod_val):,}'
        else:
            year1_str = '—'
    elif isinstance(year1_raw, dict):
        year1_str = year1_raw.get('total_year1_midpoint', '—')
        if isinstance(year1_str, str) and 'EUR' in year1_str.upper():
            year1_str = year1_str.replace('EUR ', '€')
    elif isinstance(year1_raw, (int, float)) and year1_raw:
        year1_str = f'€{int(year1_raw):,}'
    else:
        year1_str = '—'

    return [
        {'metric': 'Companies analyzed', 'value': str(dataset_size)},
        {'metric': 'Tier A targets (score 18+)', 'value': f'{tier_a} ({round(tier_a / dataset_size * 100, 1) if dataset_size else 0}%)'},
        {'metric': 'Estimated Year 1 pipeline', 'value': year1_str},
        {'metric': 'False positives flagged', 'value': f'{fp_count} Tier A companies'},
    ]


def transform_top_actions(exec_summary, strategic=None):
    """Build top actions from executive_summary.top_3_actions or strategic revenue insights."""
    actions = safe_get(exec_summary, 'top_3_actions', default=[])
    # Fallback: derive from strategic_revenue_insights in revenue_potential
    if not actions and strategic:
        rev_insights = safe_get(strategic, 'revenue_potential', 'strategic_revenue_insights', default=[])
        if rev_insights:
            actions = rev_insights[:3]
    colors = ['#EF4444', '#3B82F6', '#F59E0B']
    priorities = ['IMMEDIATE', 'CAMPAIGN', 'REVIEW']
    return [{
        'priority': priorities[i] if i < len(priorities) else 'ACTION',
        'color': colors[i] if i < len(colors) else '#6366F1',
        'text': action,
    } for i, action in enumerate(actions)]


def transform_research_stats(metadata):
    """Build research stats from metadata."""
    dataset_size = metadata.get('dataset_size', 500)
    verts = safe_get(metadata, 'verticals', default={})
    dims = safe_get(metadata, 'dimensions_per_vertical', default={})

    stats = [
        {'metric': 'Companies deep-researched', 'value': str(dataset_size)},
        {'metric': 'Research agents deployed', 'value': '20 (parallel)'},
        {'metric': 'Dimensions scored per company', 'value': '12 (vertical-specific)'},
        {'metric': 'Maximum possible score', 'value': '24'},
        {'metric': 'Companies selected for final ranking', 'value': str(dataset_size)},
    ]
    return stats


def transform_priority_20(commercial):
    """commercial.priority_20 → top 20 company profiles with full detail."""
    p20 = safe_get(commercial, 'priority_20', default=[])
    result = []
    for i, c in enumerate(p20):
        # Handle outreach_angle as string or list
        angles = c.get('recommended_outreach_angle', c.get('outreach_angle', []))
        if isinstance(angles, str):
            angles = [angles]
        # Handle urgency_signals as string or list
        usigs = c.get('urgency_signals', [])
        if isinstance(usigs, str):
            usigs = [usigs]
        result.append({
            'rank': c.get('rank', i + 1),
            'company': c.get('name', ''),
            'vertical': c.get('vertical', ''),
            'tier': c.get('tier', ''),
            'score': c.get('composite_score', c.get('score', 0)),
            'priority_score': c.get('combined_priority_score', c.get('priority_score', 0)),
            'contact': c.get('contact', ''),
            'location': c.get('location', c.get('city', '')),
            'urgency_signals': usigs,
            'outreach_angles': angles,
            'why_first': c.get('why_contact_first', c.get('why_first', '')),
        })
    return result


def transform_outreach_campaigns(commercial):
    """commercial.outreach_campaigns → 6 campaign objects."""
    campaigns = safe_get(commercial, 'outreach_campaigns', default=[])
    return [{
        'name': c.get('campaign_name', c.get('name', '')),
        'vertical': c.get('target_vertical', c.get('target_segment', (c.get('verticals', [''])[0] if isinstance(c.get('verticals'), list) else ''))),
        'profile': c.get('target_profile', c.get('target', '')),
        'angle': c.get('outreach_angle', c.get('messaging_angle', c.get('messaging', ''))),
        'count': c.get('company_count', 0),
        'companies': c.get('companies', c.get('example_companies', [])),
        'avg_score': c.get('avg_score', 0),
        'tier_a': c.get('tier_a_count', 0),
    } for c in campaigns]


def transform_urgency_signals(commercial):
    """commercial.urgency_signals → signals ranked + hot companies."""
    urgency = safe_get(commercial, 'urgency_signals', default={})

    # Try primary path
    signals_ranked = safe_get(urgency, 'signals_ranked', default=None)
    # Fallback: by_type (dict of signal_name → data)
    if not signals_ranked:
        by_type = safe_get(urgency, 'by_type', default=None)
        if isinstance(by_type, dict):
            signals_ranked = [{
                'signal': sig_name,
                'count': sig_data.get('count', 0) if isinstance(sig_data, dict) else 0,
                'pct_of_total': sig_data.get('pct', sig_data.get('pct_of_total', 0)) if isinstance(sig_data, dict) else 0,
                'tier_distribution': sig_data.get('tier_distribution', sig_data.get('tier_dist', {})) if isinstance(sig_data, dict) else {},
                'example_companies': sig_data.get('example_companies', sig_data.get('examples', [])) if isinstance(sig_data, dict) else [],
            } for sig_name, sig_data in by_type.items()]
    # Fallback: direct array or nested
    if not signals_ranked:
        if isinstance(urgency, list):
            signals_ranked = urgency
        elif isinstance(urgency, dict):
            signals_ranked = urgency.get('signals', urgency.get('signals_ranked', []))

    signals = [{
        'signal': s.get('signal', ''),
        'count': s.get('count', 0),
        'pct': s.get('pct_of_total', s.get('pct', 0)),
        'tier_a': s.get('tier_distribution', {}).get('A', 0) if isinstance(s.get('tier_distribution'), dict) else 0,
        'examples': s.get('example_companies', s.get('examples', [])),
    } for s in (signals_ranked if isinstance(signals_ranked, list) else [])]

    # Try primary path for hot companies
    hot_raw = safe_get(urgency, 'companies_with_3plus_signals', default=None)
    # Fallback: multi_signal_companies (both in urgency and commercial top-level)
    if not hot_raw:
        hot_raw = safe_get(urgency, 'multi_signal_companies', default=None)
    if not hot_raw:
        hot_raw = safe_get(commercial, 'multi_signal_companies', default=None)
    if not hot_raw:
        hot_raw = safe_get(urgency, 'hot_companies', default=[])

    hot_companies = [{
        'name': c.get('name', c.get('company', '')),
        'signals': c.get('signals', []),
        'count': c.get('signal_count', len(c.get('signals', []))),
        'tier': c.get('tier', ''),
        'score': c.get('score', 0),
    } for c in (hot_raw if isinstance(hot_raw, list) else [])]

    return {'signals': signals, 'hot_companies': hot_companies}


def transform_competitive_landscape(section2):
    """strategic.section_2_competitive_landscape → CRM tools, funding, investors, or market overview."""
    if not section2:
        return {'crm_tools': [], 'crm_insight': '', 'funding_stages': [],
                'funding_insight': '', 'investors': [], 'investor_insight': ''}

    result = {}

    # CRM tools (Accelr format)
    crm_raw = safe_get(section2, 'crm_tools_mentioned', default={})
    crm_tools = [{
        'tool': tool,
        'count': data.get('count', 0),
        'companies': data.get('example_companies', []),
    } for tool, data in crm_raw.items() if isinstance(data, dict)]
    crm_tools.sort(key=lambda x: -x['count'])
    result['crm_tools'] = crm_tools
    result['crm_insight'] = section2.get('crm_insight', '')

    # Funding stages (Accelr format)
    funding_raw = safe_get(section2, 'funding_stages', default={})
    funding_stages = [{
        'stage': stage,
        'count': data.get('count', 0),
        'companies': data.get('example_companies', []),
    } for stage, data in funding_raw.items() if isinstance(data, dict)]
    funding_stages.sort(key=lambda x: -x['count'])
    result['funding_stages'] = funding_stages
    result['funding_insight'] = section2.get('funding_insight', '')

    # Investors (Accelr format)
    investor_raw = safe_get(section2, 'notable_investors', default={})
    investors = [{
        'name': name,
        'count': data.get('count', 0),
        'portfolio': data.get('portfolio_companies', []),
    } for name, data in investor_raw.items() if isinstance(data, dict)]
    investors.sort(key=lambda x: -x['count'])
    result['investors'] = investors
    result['investor_insight'] = section2.get('investor_insight', '')

    # Market status (both formats)
    result['market_status'] = section2.get('market_status', '')

    # Competitor presence (supervision/IAM format)
    cp = section2.get('competitor_presence', None)
    if cp:
        result['competitor_presence'] = cp

    # Displacement playbook (supervision/IAM format)
    dp = section2.get('displacement_playbook', section2.get('displacement', None))
    if dp:
        result['displacement_playbook'] = dp

    # Greenfield percentage
    gf = section2.get('greenfield_pct', None)
    if gf is not None:
        result['greenfield_pct'] = gf

    return result


def transform_contact_analysis(commercial):
    """commercial.contact_analysis → categories + insight."""
    ca = safe_get(commercial, 'contact_analysis', default={})
    if not ca:
        return {'categories': [], 'insight': ''}

    # Try multiple key names for role data
    roles = safe_get(ca, 'role_categories', default=None)
    if not roles:
        roles = safe_get(ca, 'role_distribution', default=None)
    if not roles and isinstance(ca, list):
        roles = ca
    if not roles:
        roles = ca.get('categories', ca.get('roles', [])) if isinstance(ca, dict) else []

    # Handle both list-of-dicts and dict-of-dicts formats
    if isinstance(roles, dict):
        # Format: {"CEO/Founder": {"count": 180, "avg_score": 12.5, ...}, ...}
        categories = [{
            'category': role_name,
            'count': data.get('count', 0) if isinstance(data, dict) else 0,
            'pct': data.get('pct_of_total', data.get('pct', 0)) if isinstance(data, dict) else 0,
            'avg_score': data.get('avg_score', 0) if isinstance(data, dict) else 0,
            'tier_a': data.get('tier_a_count', data.get('tier_a', 0)) if isinstance(data, dict) else 0,
        } for role_name, data in roles.items()]
    else:
        categories = [{
            'category': r.get('category', r.get('role', '')),
            'count': r.get('count', 0),
            'pct': r.get('pct_of_total', r.get('pct', 0)),
            'avg_score': r.get('avg_score', 0),
            'tier_a': r.get('tier_a_count', r.get('tier_a', 0)),
        } for r in (roles if isinstance(roles, list) else [])]

    # Build insight from various formats
    fvd = safe_get(ca, 'founder_vs_dedicated_sales', default=None)
    if fvd:
        founder = safe_get(fvd, 'founder_doing_sales', default={})
        dedicated = safe_get(fvd, 'dedicated_sales_person', default={})
        insight = (f"Founder/CEO doing sales: {founder.get('count', 0)} ({founder.get('pct', 0)}%), "
                   f"Dedicated sales person: {dedicated.get('count', 0)} ({dedicated.get('pct', 0)}%)")
    else:
        # Build insight from founder_sales_ratio if available
        fsr = ca.get('founder_sales_ratio', None)
        if isinstance(fsr, dict):
            insight = f"Founder-led sales: {fsr.get('founder_led', {}).get('count', 0)} companies ({fsr.get('founder_led', {}).get('pct', 0)}%)"
        elif isinstance(fsr, (int, float)):
            insight = f"Founder-led sales ratio: {round(fsr * 100, 1)}%"
        else:
            insight = ''

    return {'categories': categories, 'insight': insight}


def transform_dimension_correlations(commercial):
    """commercial.dimension_correlations → structured dict or per-vertical pairs.

    The data can come in two formats:
    - Format A (Joinly/IAM): Top-level keys: distributions, top_co_occurring_pairs, tier_a_lift, per_vertical, hardest_to_detect
    - Format B (Accelr): Per-vertical keys with co-occurring pairs inside
    If format A is detected, pass through as structured dict (component handles it).
    If format B, transform to array of {vertical, pairs}.
    """
    dc = safe_get(commercial, 'dimension_correlations', default={})
    if not dc:
        return {}
    # Fallback: if it's a list already, return directly
    if isinstance(dc, list):
        return dc

    # Detect Format A: has known top-level keys (including 'overall' which wraps them)
    format_a_keys = {'distributions', 'top_co_occurring_pairs', 'tier_a_lift', 'per_vertical', 'hardest_to_detect'}
    # If 'overall' key exists, promote its contents to top level for Format A detection
    if 'overall' in dc and isinstance(dc['overall'], dict):
        overall = dc['overall']
        # Build a merged Format A structure from 'overall' + per-vertical data
        result = {}
        # Distributions from per-vertical data
        per_vert = {}
        for vk, vdata in dc.items():
            if vk == 'overall' or not isinstance(vdata, dict):
                continue
            per_vert[vk] = vdata
        if per_vert:
            result['per_vertical'] = per_vert
        # Top co-occurring pairs from overall
        pairs = overall.get('top_co_occurring_pairs', [])
        if pairs:
            result['top_co_occurring_pairs'] = pairs
        # Tier A predictors → tier_a_lift
        predictors = overall.get('tier_a_predictors', [])
        if predictors:
            result['tier_a_lift'] = {p.get('dim', f'd{i}'): {
                'label': p.get('dim', ''),
                'lift': p.get('lift', 0),
                'overall_rate': p.get('overall_2_rate', 0),
                'tier_a_rate': p.get('tier_a_2_rate', 0),
            } for i, p in enumerate(predictors)}
        # Hardest to detect
        htd = overall.get('hardest_to_detect', [])
        if htd:
            result['hardest_to_detect'] = htd
        # Tier A combos
        combos = overall.get('tier_a_combos', [])
        if combos:
            result['tier_a_combos'] = combos
        return result

    if format_a_keys.intersection(dc.keys()):
        # Format A — transform distributions from dict-of-dicts to array-of-dicts for component
        result = {}

        # Distributions: dict keyed by dimension name → array
        dists = dc.get('distributions', {})
        if isinstance(dists, dict) and dists:
            # Check if values are dicts (Format A) or already have 'dimension' key
            first_val = next(iter(dists.values()), None)
            if isinstance(first_val, dict) and 'dimension' not in first_val:
                # Transform dict-of-dicts to array
                result['distributions'] = [
                    {'dimension': dim_name, **stats}
                    for dim_name, stats in dists.items()
                ]
            else:
                result['distributions'] = list(dists.values()) if isinstance(first_val, dict) else []
        elif isinstance(dists, list):
            result['distributions'] = dists

        # Top co-occurring pairs: pass through
        pairs = dc.get('top_co_occurring_pairs', [])
        if isinstance(pairs, list):
            result['top_co_occurring_pairs'] = pairs

        # Tier A lift: pass through (dict or list)
        tal = dc.get('tier_a_lift', {})
        if tal:
            result['tier_a_lift'] = tal

        # Per vertical: pass through
        pv = dc.get('per_vertical', {})
        if pv:
            result['per_vertical'] = pv

        # Hardest to detect: pass through
        htd = dc.get('hardest_to_detect', [])
        if htd:
            result['hardest_to_detect'] = htd

        return result

    # Format B: per-vertical co-occurring pairs
    result = []
    for vertical, data in dc.items():
        if not isinstance(data, dict):
            continue
        pairs_raw = safe_get(data, 'top_co_occurring_2s', default=None)
        if not pairs_raw:
            pairs_raw = safe_get(data, 'co_occurring_pairs', default=None)
        if not pairs_raw:
            pairs_raw = safe_get(data, 'correlations', default=[])
        pairs = [{
            'dim_1': p.get('dim_1', ''),
            'dim_2': p.get('dim_2', ''),
            'count': p.get('count', 0),
            'pct': p.get('pct_of_vertical', 0),
        } for p in (pairs_raw if isinstance(pairs_raw, list) else [])]
        result.append({'vertical': vertical, 'pairs': pairs})
    return result


def _extract_competitors(section2, strategic=None):
    """Extract competitor list from competitive landscape or false_positives data."""
    result = []

    if section2:
        # Try technology_platforms which often contains competitor tools
        tech = safe_get(section2, 'technology_platforms', default={})
        if isinstance(tech, dict):
            for name, data in tech.items():
                if isinstance(data, dict):
                    result.append({
                        'name': name,
                        'count': data.get('count', 0),
                        'companies': data.get('example_companies', []),
                    })

    # Fallback: extract competitor mentions from false_positives (IAM playbooks)
    if not result and strategic:
        fps = safe_get(strategic, 'false_positives', default=[])
        competitor_names = set()
        for fp in fps:
            reason = fp.get('reason', '') if isinstance(fp, dict) else ''
            # Look for known IAM competitor mentions
            for comp in ['HelloID', 'NetIQ', 'OneIdentity', 'One Identity', 'Okta', 'SailPoint', 'CyberArk', 'Azure AD', 'Entra ID']:
                if comp.lower() in reason.lower() and comp not in competitor_names:
                    competitor_names.add(comp)

    # Sort by count descending
    result.sort(key=lambda x: -x.get('count', 0))
    return result[:15]


def load_top25_from_csv(csv_path):
    """Load top 25 companies from priority ranking CSV."""
    result = []
    try:
        with open(csv_path, 'r', encoding='utf-8-sig') as f:
            reader = csv.DictReader(f)
            for i, row in enumerate(reader):
                if i >= 25:
                    break
                result.append({
                    'rank': i + 1,
                    'company': row.get('Company', row.get('name', row.get('Name', ''))),
                    'vertical': row.get('Vertical', row.get('vertical', '')),
                    'score': int(row.get('Composite_Score', row.get('composite_score', row.get('Score', 0)))),
                    'contact': row.get('Contact_Name', row.get('contact_name', '')),
                    'title': row.get('Contact_Title', row.get('contact_title', '')),
                })
    except Exception as e:
        print(f"  ⚠ Could not load CSV: {e}", file=sys.stderr)
    return result


def main():
    if len(sys.argv) < 4:
        print("Usage: lumos-transform.py <commercial.json> <strategic.json> <output.json> [--priority-ranking <csv>]")
        sys.exit(1)

    commercial_path = sys.argv[1]
    strategic_path = sys.argv[2]
    output_path = sys.argv[3]
    csv_path = None
    client_name = None

    if '--priority-ranking' in sys.argv:
        idx = sys.argv.index('--priority-ranking')
        if idx + 1 < len(sys.argv):
            csv_path = sys.argv[idx + 1]

    if '--client-name' in sys.argv:
        idx = sys.argv.index('--client-name')
        if idx + 1 < len(sys.argv):
            client_name = sys.argv[idx + 1]

    # Load input files
    print("═══════════════════════════════════════════════")
    print(" LUMOS MAXIMA — Report Data Transformer")
    print("═══════════════════════════════════════════════")

    try:
        with open(commercial_path, 'r') as f:
            commercial = json.load(f)
        print(f"  ✓ Loaded commercial analysis ({os.path.getsize(commercial_path) // 1024} KB)")
    except Exception as e:
        print(f"  ✗ Failed to load commercial analysis: {e}")
        commercial = {}

    try:
        with open(strategic_path, 'r') as f:
            strategic = json.load(f)
        print(f"  ✓ Loaded strategic analysis ({os.path.getsize(strategic_path) // 1024} KB)")
    except Exception as e:
        print(f"  ✗ Failed to load strategic analysis: {e}")
        strategic = {}

    # Extract sections — handle multiple key naming conventions
    metadata = safe_get(strategic, 'metadata', default=None) or safe_get(strategic, 'meta', default={})
    # Normalize metadata: ensure 'dataset_size' and 'verticals' exist
    if metadata and 'dataset_size' not in metadata:
        metadata['dataset_size'] = metadata.get('total_companies', 500)
    # Build verticals from commercial per-vertical dimension_correlations if missing
    if metadata and 'verticals' not in metadata:
        dc = safe_get(commercial, 'dimension_correlations', default={})
        if isinstance(dc, dict):
            vert_keys = [k for k in dc.keys() if k != 'overall']
            if vert_keys:
                # Try to get counts from CSV if available
                vert_counts = {}
                if csv_path:
                    try:
                        with open(csv_path, 'r', encoding='utf-8-sig') as vf:
                            vreader = csv.DictReader(vf)
                            for vrow in vreader:
                                v = vrow.get('Vertical', vrow.get('vertical', ''))
                                vert_counts[v] = vert_counts.get(v, 0) + 1
                    except Exception:
                        pass
                if not vert_counts:
                    # Fallback: use per-vertical company_count from dimension_correlations
                    for vk in vert_keys:
                        vdata = dc.get(vk, {})
                        vert_counts[vk] = vdata.get('company_count', 0) if isinstance(vdata, dict) else 0
                metadata['verticals'] = vert_counts

    exec_summary = safe_get(strategic, 'executive_summary', default={})
    section1 = safe_get(strategic, 'section_1_sweet_spot_profile', default=None) or safe_get(strategic, 'sweet_spot_profile', default={})
    section2 = safe_get(strategic, 'section_2_competitive_landscape', default=None) or safe_get(strategic, 'competitive_landscape', default={})
    # section4: also try top-level false_positives wrapped in a dict
    section4 = safe_get(strategic, 'section_4_risk_assessment', default=None) or safe_get(strategic, 'risk_assessment', default=None)
    if not section4:
        # Build section4 from top-level false_positives array
        fp_list = strategic.get('false_positives', [])
        if fp_list:
            section4 = {
                'false_positive_tier_a_candidates': fp_list,
                'false_positive_count': len([fp for fp in fp_list if isinstance(fp, dict) and fp.get('recommended_action') == 'downgrade']),
            }
        else:
            section4 = {}
    # section5: also try top-level campaign_segments
    section5 = safe_get(strategic, 'section_5_campaign_clustering', default=None) or safe_get(strategic, 'campaign_clustering', default=None)
    if not section5:
        cs_list = strategic.get('campaign_segments', [])
        if cs_list:
            section5 = {'segments': cs_list}
        else:
            section5 = {}
    section6 = safe_get(strategic, 'section_6_revenue_potential', default=None) or safe_get(strategic, 'revenue_potential', default={})

    # Transform each field
    print("\n  Transforming fields...")
    mapped = []
    defaulted = []

    tiers = transform_tiers(metadata)
    verticals = transform_verticals(metadata)

    def track(name, value, empty_check=None):
        if empty_check is None:
            empty_check = not value or (isinstance(value, (list, dict)) and len(value) == 0)
        if empty_check:
            defaulted.append(name)
        else:
            mapped.append(name)
        return value

    # Build top_25 from CSV or strategic analysis
    top25 = []
    if csv_path:
        top25 = load_top25_from_csv(csv_path)
    if not top25:
        top25 = transform_top25(section1)

    report_data = {
        'meta': {
            'client_name': client_name or metadata.get('client_name') or Path(commercial_path).parent.name.title() or 'Client',
            'contact_name': '',
            'campaign': '',
            'market': '',
            'date': metadata.get('analysis_date', ''),
            'prepared_by': 'iSyncso Growth Commercial Engine',
            'classification': 'Client-facing Strategic Document',
            'data_basis': f"{sum(v for v in metadata.get('verticals', {}).values() if isinstance(v, (int, float)))} companies deep-researched → {metadata.get('dataset_size', 500)} ranked",
            'analysis': f"Commercial + Strategic analyst engines",
        },
        'headline': track('headline', transform_headline(metadata, tiers, section6)),
        'verticals': track('verticals', verticals),
        'tiers': track('tiers', tiers, not tiers.get('A', {}).get('count')),
        'score_distribution': track('score_distribution', transform_score_distribution(
            section1, csv_path=csv_path,
            tier_thresholds=safe_get(metadata, 'tier_score_ranges', default=None))),
        'vertical_scorecards': track('vertical_scorecards', transform_vertical_scorecards(metadata, section1)),
        'top_differentiators': track('top_differentiators', transform_top_differentiators(section1, commercial)),
        'narrative_patterns': track('narrative_patterns', transform_narrative_patterns(commercial)),
        'revenue_pipeline': track('revenue_pipeline', transform_revenue_pipeline(section6), not section6),
        'campaign_segments': track('campaign_segments', transform_campaign_segments(section5)),
        'geographic': track('geographic', transform_geographic(commercial)),
        'false_positives': track('false_positives', transform_false_positives(section4)),
        'top_25': track('top_25', top25),
        'competitors': track('competitors', _extract_competitors(section2, strategic)),
        'outreach_waves': track('outreach_waves', transform_outreach_waves(tiers)),
        'key_insights': track('key_insights', safe_get(commercial, 'key_insights', default=[])),
        'executive_metrics': track('executive_metrics', transform_executive_metrics(metadata, section6, section4)),
        'top_actions': track('top_actions', transform_top_actions(exec_summary, strategic)),
        'research_stats': track('research_stats', transform_research_stats(metadata)),
        'priority_20': track('priority_20', transform_priority_20(commercial)),
        'outreach_campaigns': track('outreach_campaigns', transform_outreach_campaigns(commercial)),
        'urgency_signals': track('urgency_signals', transform_urgency_signals(commercial),
                                 not safe_get(commercial, 'urgency_signals', default={})),
        'competitive_landscape': track('competitive_landscape', transform_competitive_landscape(section2),
                                       not section2),
        'contact_analysis': track('contact_analysis', transform_contact_analysis(commercial),
                                  not safe_get(commercial, 'contact_analysis', default={})),
        'dimension_correlations': track('dimension_correlations', transform_dimension_correlations(commercial)),
    }

    # Pass through extra top-level keys from strategic/commercial that aren't in our schema
    # This catches playbook-specific fields like under_scored_candidates, revenue_potential, etc.
    extra_sources = [('strategic', strategic), ('commercial', commercial)]
    extra_count = 0
    for source_name, source in extra_sources:
        if not source:
            continue
        for key in source:
            if key not in report_data and key not in ('metadata', 'analysis_metadata', 'meta'):
                val = source[key]
                if val is not None and val != '' and val != [] and val != {}:
                    report_data[key] = val
                    extra_count += 1
    if extra_count:
        print(f"  + Passed through {extra_count} extra fields from source data")

    # ── CSV-based enrichment pass ──
    # Many analysis JSONs don't include cross-referenced stats (per-role tier_a,
    # per-segment avg_score, etc). Compute them from the CSV when available.
    if csv_path and os.path.exists(csv_path):
        print("\n  Enriching from CSV...")
        try:
            from collections import Counter, defaultdict
            with open(csv_path, 'r', encoding='utf-8-sig') as f:
                csv_rows = list(csv.DictReader(f))

            by_domain = {}
            by_name = {}
            for r in csv_rows:
                d = r.get('Domain', '').lower().strip()
                if d:
                    by_domain[d] = r
                n = r.get('Name', '').lower().strip()
                if n:
                    by_name[n] = r

            csv_total = len(csv_rows)
            tier_counts = Counter(r.get('Tier', '') for r in csv_rows)

            # Fix tiers from actual CSV (post-downgrade)
            for tier in ['A', 'B', 'C', 'D']:
                count = tier_counts.get(tier, 0)
                pct = round(count / csv_total * 100, 1) if csv_total else 0
                report_data['tiers'][tier] = {'count': count, 'pct': pct}

            # Fix headline Tier A
            tier_a_count = tier_counts.get('A', 0)
            for h in report_data.get('headline', []):
                if 'Tier A' in h.get('label', ''):
                    h['value'] = str(tier_a_count)

            # Fix vertical scorecards
            vert_tiers = defaultdict(lambda: Counter())
            vert_scores = defaultdict(list)
            vert_top = {}
            for r in csv_rows:
                v = r.get('Vertical', '')
                t = r.get('Tier', '')
                s = int(r.get('Composite_Score', 0))
                vert_tiers[v][t] += 1
                vert_scores[v].append(s)
                if v not in vert_top or s > vert_top[v][0]:
                    vert_top[v] = (s, r.get('Name', ''))

            for vs in report_data.get('vertical_scorecards', []):
                vname = vs['name']
                if vname in vert_tiers:
                    vs['tier_a'] = vert_tiers[vname].get('A', 0)
                    vs['tier_b'] = vert_tiers[vname].get('B', 0)
                    vs['tier_c'] = vert_tiers[vname].get('C', 0)
                    scores = vert_scores[vname]
                    vs['avg'] = round(sum(scores) / len(scores), 1) if scores else 0
                    top_s, top_n = vert_top.get(vname, (0, ''))
                    vs['top'] = top_s
                    vs['top_company'] = top_n

            # Fix campaign segments avg_score and tier_a from example companies
            strat_segments = strategic.get('campaign_segments', [])
            if not strat_segments:
                strat_segments = safe_get(strategic, 'section_5_campaign_clustering', 'segments', default=[])
            for i, seg in enumerate(report_data.get('campaign_segments', [])):
                strat_seg = strat_segments[i] if i < len(strat_segments) else {}
                example_domains = strat_seg.get('example_companies', [])
                matched = [by_domain[d.lower().strip()] for d in example_domains
                           if d.lower().strip() in by_domain]
                if matched:
                    scores = [int(m.get('Composite_Score', 0)) for m in matched]
                    seg['avg'] = round(sum(scores) / len(scores), 1)
                    seg['tier_a'] = sum(1 for m in matched if m.get('Tier') == 'A')

            # Fix contact analysis tier_a from CSV
            role_tier_a = defaultdict(int)
            for r in csv_rows:
                if r.get('Tier') == 'A':
                    title = r.get('Contact_Title', '').lower()
                    if any(t in title for t in ['founder', 'co-founder', 'oprichter']):
                        role_tier_a['Founder/Co-Founder'] += 1
                    elif 'managing director' in title or 'directeur' in title:
                        role_tier_a['Managing Director'] += 1
                    elif any(t in title for t in ['owner', 'partner', 'eigenaar']):
                        role_tier_a['Owner/Partner'] += 1
                    elif 'ceo' in title or 'chief executive' in title:
                        role_tier_a['CEO'] += 1
                    elif any(t in title for t in ['cto', 'cpo', 'chief tech', 'chief product']):
                        role_tier_a['CTO/CPO'] += 1
                    elif any(t in title for t in ['cro', 'chief revenue']):
                        role_tier_a['CRO'] += 1
                    elif any(t in title for t in ['head of sales', 'vp sales', 'sales director']):
                        role_tier_a['Sales Leader'] += 1
                    elif any(t in title for t in ['sales', 'bd', 'business develop']):
                        role_tier_a['Sales/BD Role'] += 1
                    else:
                        role_tier_a['Other'] += 1
            for cat in report_data.get('contact_analysis', {}).get('categories', []):
                if cat['category'] in role_tier_a:
                    cat['tier_a'] = role_tier_a[cat['category']]

            # Fix false positives rank + zero_dims from CSV
            for fp in report_data.get('false_positives', []):
                name_lower = fp.get('company', '').lower().strip()
                if name_lower in by_name:
                    r = by_name[name_lower]
                    fp['rank'] = int(r.get('Rank', 0))
                    zero_dims = sum(1 for d_i in range(1, 13)
                                    if str(r.get(f'D{d_i}_Score', '0')).strip() in ('0', ''))
                    fp['zero_dims'] = zero_dims

            # Fix priority 20 location
            for p in report_data.get('priority_20', []):
                name_lower = p.get('company', '').lower().strip()
                if name_lower in by_name:
                    p['location'] = by_name[name_lower].get('Location', '')

            # Fix urgency hot companies
            for hc in report_data.get('urgency_signals', {}).get('hot_companies', []):
                name_lower = hc.get('name', '').lower().strip()
                if name_lower in by_name:
                    r = by_name[name_lower]
                    hc['tier'] = r.get('Tier', '')
                    hc['score'] = int(r.get('Composite_Score', 0))

            # Fix outreach waves with actual tier counts
            for wave in report_data.get('outreach_waves', []):
                if 'Remaining Tier A' in wave.get('target', ''):
                    wave['volume'] = f'~{max(0, tier_a_count - 15)}'
                elif 'Top Tier B' in wave.get('target', ''):
                    wave['volume'] = f'~{tier_counts.get("B", 0) // 2}'
                elif 'Remaining Tier B' in wave.get('target', ''):
                    tb = tier_counts.get('B', 0)
                    wave['volume'] = f'~{tb - tb // 2}'
                elif 'Tier C' in wave.get('target', ''):
                    wave['volume'] = f'{tier_counts.get("C", 0)}+'

            # Fix executive metrics
            for em in report_data.get('executive_metrics', []):
                if 'Tier A' in em.get('metric', ''):
                    em['value'] = f'{tier_a_count} ({round(tier_a_count/csv_total*100, 1) if csv_total else 0}%)'

            print(f"  ✓ CSV enrichment complete ({csv_total} rows)")
        except Exception as e:
            print(f"  ⚠ CSV enrichment failed: {e}")

    # Write output
    with open(output_path, 'w') as f:
        json.dump(report_data, f, indent=2, ensure_ascii=False)

    print(f"\n  ✓ Mapped: {len(mapped)} fields ({', '.join(mapped)})")
    if defaulted:
        print(f"  ⚠ Defaulted to empty: {len(defaulted)} fields ({', '.join(defaulted)})")
    print(f"\n  → {output_path} ({os.path.getsize(output_path) // 1024} KB)")
    print("═══════════════════════════════════════════════\n")


if __name__ == '__main__':
    main()
