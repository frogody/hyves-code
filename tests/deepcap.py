#!/usr/bin/env python3
"""deepcap.py — Superboost deep animation verification (~25s, exit 0 = pass).

Captures the statusline at ~3fps across a full 7s effect life for
fanout / commit / fail and verifies FROM FRAME DATA:
  - visible width == COLUMNS-5 in EVERY frame (the width law)
  - wash decay falling to ~0 by TTL, fully dark after it
  - commit sweep monotonic left-to-right across its 3s travel
  - fanout scanner glides: moves most frames, covers most of the canvas,
    bounces at the ends — no teleporting, no freezing
  - render stays under ~80ms (mean; subprocess harness adds ~15ms overhead)

Boot-cinema decrypt progression is verified by ansi2json.py (run separately).
Companion quick suite: verify.sh. Frame parsing lives in fxcap.py.
"""
import itertools, os, statistics, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fxcap import cells, canvas_profile, wash_run, set_state, RICH, SL, FX

COLS = 150
EXPECT_W = COLS - 5
HEART_RGB = (32, 36, 46)  # base(22,24,31) + 14% toward slate(100,116,139)

def render_timed():
    t0 = time.time()
    p = subprocess.run([SL], input=RICH, capture_output=True, text=True,
                       env={**os.environ, "COLUMNS": str(COLS)})
    return p.stdout.rstrip("\n"), (time.time() - t0) * 1000

def capture(event, label, r, g, b, seconds=7.5, fps=3):
    t0 = time.time()
    set_state(event, label, r, g, b, round(t0, 2))   # float epoch, like fx.sh
    frames, times = [], []
    for k in range(int(seconds * fps)):
        target = t0 + k / fps
        now = time.time()
        if target > now:
            time.sleep(target - now)
        fr, ms = render_timed()
        frames.append((time.time() - t0, fr))
        times.append(ms)
    subprocess.run([FX, "clear"], capture_output=True)
    return frames, times

def wash_series(frames, er, eg, eb, label):
    """Per frame -> (age, start, wash-profile, total_energy, argmax)."""
    rows = []
    for age, fr in frames:
        best = wash_run(fr, canvas_profile(fr, er, eg, eb), label)
        if best is None:
            rows.append((age, -1, [], 0.0, -1))
        else:
            start, vals = best
            rows.append((age, start, vals, sum(vals), vals.index(max(vals))))
    return rows

def check(name, ok, detail):
    print(f"  {'ok  ' if ok else 'FAIL'} {name}: {detail}")
    return ok

def analyze(event, label, r, g, b):
    print(f"\n== {event} ==")
    frames, times = capture(event, label, r, g, b)
    allok = True

    widths = [len(cells(fr)) for _, fr in frames]
    allok &= check("width", all(w == EXPECT_W for w in widths),
                   f"all {len(widths)} frames == {EXPECT_W}? got {sorted(set(widths))}")

    allok &= check("render<80ms", statistics.mean(times) < 80,
                   f"mean {statistics.mean(times):.0f}ms  max {max(times):.0f}ms "
                   "(incl ~15ms harness overhead)")

    rows = wash_series(frames, r, g, b, label)
    live = [(rw[0], rw[3]) for rw in rows if rw[0] < 7.0]
    post = [rw for rw in rows if rw[0] >= 7.0]

    peak_e = max(e for _, e in live)
    early = statistics.mean(e for a, e in live if a < 2.0)
    # mid window starts at 4.0s, NOT 3.0s: the v5.2.2 hold-then-ease decay is
    # still ~96% at 3s, inside the ±10% pulse noise — early-vs-mid was a coin
    # flip there (observed flake: early 8.2 vs mid 8.2). At 4.0–5.5s the ease
    # sits near 50%, giving the comparison a real margin.
    mid = statistics.mean(e for a, e in live if 4.0 <= a < 5.5)
    tail = [e for a, e in live if a >= 6.0]
    late = statistics.mean(tail) if tail else 0.0
    allok &= check("decay", early > mid > late and late < 0.15 * peak_e,
                   f"early {early:.1f} > mid {mid:.1f} > late {late:.1f} (peak {peak_e:.1f})")

    # v5.2.2: the wash must light the WHOLE canvas at full strength — the pure
    # g^1.5 falloff left the far half black on wide terminals and the user read
    # a fresh effect as "no visual confirmation" (screenshot-verified)
    fresh = [rw[2] for rw in rows if rw[0] < 2.0 and rw[2]]
    cover = min(sum(1 for v in vals if v and v >= 0.1) / len(vals) for vals in fresh)
    allok &= check("full-canvas coverage", cover >= 0.9,
                   f"min lit fraction over ages<2s: {cover*100:.0f}% (floor 90%)")
    if post:
        # v5.3: after TTL a WORK event hands off to the slate heartbeat, so the
        # canvas is not black — but it must hold ZERO effect-colored energy.
        # Mask cells that are exactly the heartbeat color before scoring.
        post_e = []
        for age, fr in frames:
            if age < 7.0:
                continue
            prof = canvas_profile(fr, r, g, b)
            cs = cells(fr)
            prof = [0.0 if (v and cs[i][1] == HEART_RGB) else v
                    for i, v in enumerate(prof)]
            best = wash_run(fr, prof, label)
            post_e.append(0.0 if best is None else sum(best[1]))
        allok &= check("expired", all(e < 0.3 for e in post_e),
                       f"effect energy after TTL (heartbeat masked): {[round(e, 2) for e in post_e]}")

    if event == "commit":
        # sweep runs 0..3s; sample while it's live, with margin for render latency
        sweep = [(rw[4], len(rw[2])) for rw in rows if rw[0] < 2.7 and rw[2]]
        pos = [p for p, _ in sweep]
        n = sweep[0][1]
        mono = all(b2 >= a2 for a2, b2 in zip(pos, pos[1:]))
        allok &= check("sweep L->R monotonic",
                       mono and pos[0] < n * 0.35 and pos[-1] > n * 0.65,
                       f"pos={pos} n={n}")

    if event == "fanout":
        # analyze while the head is bright enough to read: past ~4s the smooth-
        # step decay leaves 1-2 quantization levels and argmax degenerates to
        # dither noise (the bar is visually near-black there)
        scan = [(rw[4], len(rw[2])) for rw in rows if rw[0] < 4.0 and rw[2]]
        pos = [p for p, _ in scan]
        n = scan[0][1]
        deltas = [b2 - a2 for a2, b2 in zip(pos, pos[1:])]
        moved = sum(1 for d in deltas if abs(d) >= 1)
        max_glide = 0.9 * (n - 1) / 3.0 + 3      # sinusoid peak speed + dither slack
        coverage = (max(pos) - min(pos)) / max(n - 1, 1)
        bounces = sum(1 for a2, b2 in zip(
            [d for d in deltas if d], [d for d in deltas if d][1:])
            if (a2 > 0) != (b2 > 0))
        frozen = max((len(list(g)) for z, g in itertools.groupby(
            deltas, key=lambda d: d == 0) if z), default=0)
        # scanner period ~3.5s -> a 4s readable window holds ONE full turnaround
        allok &= check("scanner glides",
                       moved >= 0.7 * len(deltas) and coverage >= 0.6
                       and bounces >= 1 and frozen <= 2
                       and all(abs(d) <= max_glide for d in deltas),
                       f"moved {moved}/{len(deltas)} cover {coverage:.2f} "
                       f"bounces {bounces} max|d| {max(abs(d) for d in deltas)} "
                       f"(cap {max_glide:.1f}) frozen {frozen}")
        print(f"       pos: {pos}")

    return allok

def analyze_heartbeat():
    """v5.3: an expired WORK event must leave a faint drifting slate shimmer
    (turn still running); done/attn must leave the canvas black."""
    print("\n== heartbeat ==")
    ok = True
    set_state("edit", "EDIT", 245, 158, 11, round(time.time() - 10, 2))
    frames = []
    for _ in range(4):
        fr, _ms = render_timed()
        frames.append(fr)
        time.sleep(0.4)
    widths = [len(cells(fr)) for fr in frames]
    ok &= check("width", all(w == EXPECT_W for w in widths),
                f"all {len(widths)} frames == {EXPECT_W}? got {sorted(set(widths))}")
    lit = [sum(1 for ch, bg in cells(fr) if ch == " " and bg == HEART_RGB) for fr in frames]
    ok &= check("lit after stale edit", all(n > 0 for n in lit), f"lit cells per frame: {lit}")
    patterns = [tuple(i for i, (ch, bg) in enumerate(cells(fr)) if bg == HEART_RGB) for fr in frames]
    ok &= check("drifts (wall-clock)", len(set(patterns)) > 1,
                f"{len(set(patterns))} distinct patterns over {len(frames)} frames")
    set_state("done", "DONE", 100, 116, 139, round(time.time() - 10, 2))
    fr, _ms = render_timed()
    dark = sum(1 for ch, bg in cells(fr) if bg == HEART_RGB)
    ok &= check("black after done", dark == 0, f"heartbeat cells after done: {dark}")
    subprocess.run([FX, "clear"], capture_output=True)
    return ok

if __name__ == "__main__":
    ok = True
    for ev, (lb, r, g, b) in {"fanout": ("FAN-OUT", 34, 211, 238),
                              "commit": ("COMMIT", 34, 197, 94),
                              "fail":   ("FAIL", 248, 113, 113)}.items():
        ok &= analyze(ev, lb, r, g, b)
    ok &= analyze_heartbeat()
    print("\nDEEPCAP:", "ALL PASS" if ok else "FAILURES")
    sys.exit(0 if ok else 1)
