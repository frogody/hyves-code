#!/usr/bin/env python3
"""Convert captured ANSI output to JSON segment frames for the HTML replay."""
import json, os, re, subprocess, sys, time

SGR = re.compile(r"\x1b\[([0-9;]*)m")

def line_to_segments(line):
    """One ANSI line -> [[text, fg, bg, bold], ...] with hex colors or None."""
    segs, fg, bg, bold, i = [], None, None, False, 0
    def emit(text):
        if not text: return
        if segs and segs[-1][1] == fg and segs[-1][2] == bg and segs[-1][3] == bold:
            segs[-1][0] += text
        else:
            segs.append([text, fg, bg, bold])
    for m in SGR.finditer(line):
        emit(line[i:m.start()]); i = m.end()
        parts = [int(x) for x in m.group(1).split(";") if x != ""] or [0]
        j = 0
        while j < len(parts):
            p = parts[j]
            if p == 0: fg = bg = None; bold = False; j += 1
            elif p == 1: bold = True; j += 1
            elif p == 2: j += 1                     # dim: approximate as normal
            elif p in (38, 48) and j + 4 < len(parts) and parts[j+1] == 2:
                col = "#%02x%02x%02x" % (parts[j+2], parts[j+3], parts[j+4])
                if p == 38: fg = col
                else: bg = col
                j += 5
            else: j += 1
    emit(line[i:])
    return segs

def capture_statusline(event, label, r, g, b, seconds=7, fps=3):
    sl = os.path.expanduser("~/.claude/hooks/superboost-statusline.sh")
    state = os.path.expanduser("~/.claude/fx/state")
    rich = json.dumps({"model": {"display_name": "Fable 5"},
        "cost": {"total_cost_usd": 4.56, "total_lines_added": 123, "total_lines_removed": 45},
        "context_window": {"used_percentage": 42.5},
        "rate_limits": {"five_hour": {"used_percentage": 10}},
        "effort": {"level": "xhigh"},
        "workspace": {"current_dir": "/Users/x/app.isyncso"}})
    t0 = time.time()
    with open(state, "w") as f:
        f.write(f"{event}|{label}|{r}|{g}|{b}|{t0:.2f}|7\n")
    frames = []
    for k in range(seconds * fps):
        out = subprocess.run([sl], input=rich, capture_output=True, text=True,
                             env={**os.environ, "COLUMNS": "150"}).stdout.rstrip("\n")
        frames.append(line_to_segments(out))
        time.sleep(1.0 / fps)
    os.remove(state)
    return frames

def capture_boot():
    """Run hyves-boot under a PTY, split on sync-begin markers."""
    out = subprocess.run(
        ["script", "-q", "/dev/null", os.path.expanduser("~/.claude/hooks/hyves-boot.sh")],
        capture_output=True, text=True, env={**os.environ, "HYVES_BOOT_FRAMES": "40"},
    ).stdout.replace("\r\n", "\n").replace("\r", "\n")
    chunks = out.split("\x1b[?2026h")[1:]           # each chunk = one synced frame (+tail junk)
    frames = []
    for ch in chunks:
        ch = ch.split("\x1b[?2026l")[0]
        ch = ch.replace("\x1b[H", "")
        lines = [l for l in ch.split("\n")]
        # trim leading/trailing blank pad rows
        while lines and not SGR.sub("", lines[0]).strip(): lines.pop(0)
        while lines and not SGR.sub("", lines[-1]).strip(): lines.pop()
        frames.append([line_to_segments(l) for l in lines])
    return frames, out

if __name__ == "__main__":
    data = {"statusline": {}, "boot": []}
    for ev, (lb, r, g, b) in {"fanout": ("FAN-OUT", 34, 211, 238),
                              "commit": ("COMMIT", 34, 197, 94),
                              "fail":   ("FAIL", 248, 113, 113)}.items():
        print(f"capturing statusline:{ev} (7s)...", flush=True)
        data["statusline"][ev] = capture_statusline(ev, lb, r, g, b)
    print("capturing boot cinema...", flush=True)
    boot, raw = capture_boot()
    data["boot"] = boot

    # verify decrypt progression: resolved fraction vs the final frame
    final_text = ["".join(s[0] for s in line) for line in boot[-1]]
    fracs = []
    for fr in boot:
        text = ["".join(s[0] for s in line) for line in fr]
        tot = same = 0
        for a, b_ in zip(text, final_text):
            for ca, cb in zip(a.ljust(len(b_)), b_):
                if cb != " ":
                    tot += 1
                    if ca == cb: same += 1
        fracs.append(round(same / max(tot, 1), 2))
    print(f"boot frames: {len(boot)}, resolve fraction: {fracs}")
    nondecr = all(b_ >= a - 0.06 for a, b_ in zip(fracs, fracs[1:]))
    print(f"VERDICT decrypt progression (allowing scramble noise): {nondecr}, ends at {fracs[-1]}")

    with open("fxcapture.json", "w") as f:
        json.dump(data, f)
    print(f"wrote fxcapture.json ({os.path.getsize('fxcapture.json')//1024} KB)")
