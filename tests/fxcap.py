#!/usr/bin/env python3
"""Capture + analyze Superboost statusline FX animation frames."""
import json, os, re, subprocess, sys, time

SL = os.path.expanduser("~/.claude/hooks/superboost-statusline.sh")
FX = os.path.expanduser("~/.claude/hooks/superboost-fx.sh")
STATE = os.path.expanduser("~/.claude/fx/state")
RICH = json.dumps({
    "model": {"display_name": "Fable 5"},
    "cost": {"total_cost_usd": 4.56, "total_lines_added": 123, "total_lines_removed": 45},
    "context_window": {"used_percentage": 42.5},
    "rate_limits": {"five_hour": {"used_percentage": 10}},
    "effort": {"level": "xhigh"},
    "workspace": {"current_dir": "/Users/x/app.isyncso"},
})

SGR = re.compile(r"\x1b\[([0-9;]*)m")

def render(cols=160):
    p = subprocess.run([SL], input=RICH, capture_output=True, text=True,
                       env={**os.environ, "COLUMNS": str(cols)})
    return p.stdout.rstrip("\n")

def cells(frame):
    """Walk ANSI string -> list of (char, bg_rgb)."""
    out, bg, i = [], None, 0
    for m in SGR.finditer(frame):
        for ch in frame[i:m.start()]:
            out.append((ch, bg))
        i = m.end()
        parts = [int(x) for x in m.group(1).split(";") if x != ""] or [0]
        j = 0
        while j < len(parts):
            if parts[j] == 0: bg = None; j += 1
            elif parts[j] == 48 and j + 4 < len(parts) and parts[j+1] == 2:
                bg = (parts[j+2], parts[j+3], parts[j+4]); j += 5
            elif parts[j] == 38 and j + 4 < len(parts) and parts[j+1] == 2:
                j += 5
            else: j += 1
    for ch in frame[i:]:
        out.append((ch, bg))
    return out

def canvas_profile(frame, er, eg, eb):
    """Alpha-toward-effect per SPACE cell. A cell only scores if EVERY significant
    channel moved toward the effect color proportionally (rejects the RAM bar)."""
    base = (22, 24, 31); eff = (er, eg, eb)
    prof = []
    for ch, bg in cells(frame):
        if ch != " " or bg is None:
            prof.append(None); continue
        ratios = []
        ok = True
        for c, bc, ec in zip(bg, base, eff):
            d = ec - bc
            if abs(d) < 30:
                continue
            t = (c - bc) / d
            if t < -0.08:
                ok = False; break
            ratios.append(t)
        if not ok or not ratios:
            prof.append(0.0); continue
        if max(ratios) - min(ratios) > 0.25:   # channels disagree -> not this effect
            prof.append(0.0); continue
        prof.append(round(sum(ratios) / len(ratios), 3))
    return prof

def set_state(event, label, r, g, b, t, ttl=7):
    with open(STATE, "w") as f:
        f.write(f"{event}|{label}|{r}|{g}|{b}|{t}|{ttl}\n")

def capture(event, label, r, g, b, seconds=8, per_sec=2):
    # float epoch, matching what fx.sh writes since v5.2.1 (an int-truncated
    # epoch started animation phases up to 1s late)
    t0 = round(time.time(), 2)
    set_state(event, label, r, g, b, t0)
    frames = []
    for k in range(seconds * per_sec):
        frames.append((time.time() - t0, render()))
        time.sleep(1.0 / per_sec)
    return frames

def runs(prof, minlen=8):
    out, cur, start = [], 0, 0
    for idx, v in enumerate(prof):
        if v is not None:
            if cur == 0: start = idx
            cur += 1
        else:
            if cur >= minlen: out.append((start, prof[start:start + cur]))
            cur = 0
    if cur >= minlen: out.append((start, prof[start:start + cur]))
    return out

def wash_run(frame, prof, label=None):
    """The wash canvas is the RIGHTMOST long space-run (it sits just left of the
    FX label). Two traps this dodges:
      - Selecting by max energy is wrong: the RAM bar's left cells are literally
        commit-green (t=1.0), so for green effects it out-scores a decayed wash
        and masquerades as the canvas.
      - The label chip's leading pad space (bright effect bg) is contiguous with
        the wash spaces and joins the run, pinning argmax to the right end —
        truncate at the label's pad using the KNOWN label text (alpha threshold
        can't split them: the label pulses down to 0.80x, the wash caps at 0.80).
    """
    rs = runs(prof)
    if not rs:
        return None
    start, vals = rs[-1]
    if label:
        text = "".join(ch for ch, _ in cells(frame))
        ti = text.find(f" {label} ")          # index of the leading pad space
        if start <= ti < start + len(vals):
            vals = vals[:ti - start]
    return (start, vals) if vals else None

def wash_stats(frames, er, eg, eb, label=None):
    """Per frame: (age, wash_total, argmax, peak, run_len) for the wash canvas."""
    rows = []
    for age, fr in frames:
        best = wash_run(fr, canvas_profile(fr, er, eg, eb), label)
        if best is None:
            rows.append((round(age, 1), 0, -1, 0, 0)); continue
        start, vals = best
        peak = max(vals)
        rows.append((round(age, 1), round(sum(vals), 2), vals.index(peak),
                     round(peak, 2), len(vals)))
    return rows

if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "fanout"
    specs = {"fanout": ("FAN-OUT", 34, 211, 238), "commit": ("COMMIT", 34, 197, 94),
             "deploy": ("DEPLOY", 99, 102, 241), "pass": ("PASS", 74, 222, 128)}
    label, r, g, b = specs[mode]
    frames = capture(mode, label, r, g, b)
    print(f"== {mode} == (age, wash_total, argmax_pos, peak, run_len)")
    for row in wash_stats(frames, r, g, b, label):
        print("  ", row)
    subprocess.run([FX, "clear"])
