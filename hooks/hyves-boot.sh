#!/bin/bash
# hyves-boot.sh — HYVES CODE V5 cinematic boot reveal (Superboost v5.2)
# Part of Claude Code Superboost by ISYNCSO (https://isyncso.com)
#
# An nms/Sneakers-style "decrypt" of the HYVES CODE logo: every glyph holds a
# random symbol for a randomized number of frames, then resolves — fresh
# resolves flash bright phosphor green and settle. Frames are wrapped in
# DECSET 2026 synchronized output (atomic paint, no tearing; terminals that
# don't support it ignore the private mode), drawn on the ALT SCREEN with the
# cursor hidden, and a trap restores the terminal on any exit.
#
# WHERE IT RUNS: the installer, or manually (~/.claude/hooks/hyves-boot.sh).
# NEVER wire it to a Claude Code hook — hook stdout is captured into model
# context, and during a session the TUI owns the terminal.
#
# Degrades: non-TTY / NO_COLOR / narrow terminal -> one plain line, no escapes.
# Tunables: HYVES_BOOT_FRAMES (default 44 ~= 2.2s at 50ms/frame).

BANNER_OUT="$("$HOME/.claude/hooks/superboost-banner.sh" 2>/dev/null)"
# clean-boot branch: "... boot OK (28/28 checks), RAM 46.5 GB free, HEALTHY."
STATUS_LINE="$(printf '%s\n' "$BANNER_OUT" \
  | sed -n 's/.*boot OK (\([0-9]*\/[0-9]*\) checks), RAM \([0-9.]*\) GB free, \([A-Z]*\).*/boot OK · \1 checks · RAM \2 GB free · \3/p' | head -1)"
# issues branch footer: "(Superboost v5.2 | <icon> 26/29 checks | RAM 46.5 GB free | HEALTHY)"
[ -z "$STATUS_LINE" ] && STATUS_LINE="$(printf '%s\n' "$BANNER_OUT" \
  | sed -n 's/.*(Superboost v[0-9.]* | .* \([0-9]*\/[0-9]*\) checks | RAM \([0-9.]*\) GB free | \([A-Z]*\)).*/\1 checks (self-test found issues) · RAM \2 GB free · \3/p' | head -1)"
[ -z "$STATUS_LINE" ] && STATUS_LINE="self-test unavailable — run superboost-banner.sh"

COLS=$(tput cols 2>/dev/null || echo 80)
if [ ! -t 1 ] || [ -n "$NO_COLOR" ] || [ "$COLS" -lt 48 ]; then
  echo "HYVES CODE V5 — Holistic Yield & Validation Engines (by ISYNCSO)"
  echo "  $STATUS_LINE"
  exit 0
fi
ROWS=$(tput lines 2>/dev/null || echo 24)
FRAMES="${HYVES_BOOT_FRAMES:-44}"

cleanup() { printf '\033[?25h\033[?1049l'; }
trap cleanup EXIT INT TERM
printf '\033[?1049h\033[?25l\033[2J'

awk -v frames="$FRAMES" -v cols="$COLS" -v rows="$ROWS" '
BEGIN { srand() }
{ L[NR] = $0; if (length($0) > maxw) maxw = length($0) }
END {
  e = sprintf("%c", 27)
  bsu = e "[?2026h"; esu = e "[?2026l"; home = e "[H"; rst = e "[0m"
  cs = "!#$%&()*+,-./0123456789:;<=>?@[]^_{|}~abcdefghikmnopqrstuvwxz"
  cl = length(cs)
  n = NR
  padt = int((rows - n) / 2); if (padt < 0) padt = 0
  padl = int((cols - maxw) / 2); if (padl < 0) padl = 0
  # per-glyph reveal frame: staggered so the resolve rolls across the logo
  for (i = 1; i <= n; i++)
    for (j = 1; j <= maxw; j++)
      rev[i, j] = 4 + int(rand() * (frames - 12))
  for (f = 1; f <= frames + 8; f++) {
    out = bsu home
    for (p = 0; p < padt; p++) out = out "\n"
    for (i = 1; i <= n; i++) {
      line = L[i]; row = sprintf("%" padl "s", "")
      for (j = 1; j <= length(line); j++) {
        ch = substr(line, j, 1)
        if (ch == " ") { row = row " "; continue }
        if (f < rev[i, j]) {
          # still encrypted: dim phosphor, random glyph, subtle per-frame flicker
          g = 90 + int(rand() * 50)
          row = row e "[38;2;20;" g ";60m" substr(cs, int(rand() * cl) + 1, 1)
        } else {
          agef = f - rev[i, j]
          if      (agef < 2) row = row e "[38;2;187;247;208m" ch   # flash
          else if (agef < 5) row = row e "[38;2;74;222;128m" ch    # bright
          else               row = row e "[38;2;34;197;94m" ch     # settle
        }
      }
      out = out row rst "\n"
    }
    printf "%s%s", out, esu
    system("sleep 0.05")
  }
}' <<'ART'
 _   _  __   __ __     __  _____   ____
| | | | \ \ / / \ \   / / | ____| / ___|
| |_| |  \ V /   \ \ / /  |  _|   \___ \
|  _  |   | |     \ V /   | |___   ___) |
|_| |_|   |_|      \_/    |_____| |____/

          C  O  D  E     V  5
   Holistic Yield & Validation Engines
ART

cleanup
trap - EXIT INT TERM

# --- afterglow on the real screen: settled logo + live self-test status ---
G=$'\033[38;2;34;197;94m'; B=$'\033[38;2;74;222;128m'; D=$'\033[38;2;100;116;139m'; R=$'\033[0m'
printf '%s\n' "${G} _   _  __   __ __     __  _____   ____"
printf '%s\n' " | | | | \\ \\ / / \\ \\   / / | ____| / ___|" | cut -c2-
printf '%s\n' " | |_| |  \\ V /   \\ \\ / /  |  _|   \\___ \\" | cut -c2-
printf '%s\n' " |  _  |   | |     \\ V /   | |___   ___) |" | cut -c2-
printf '%s\n' " |_| |_|   |_|      \\_/    |_____| |____/${R}" | cut -c2-
printf '\n'
printf '%s\n' "${B}          C  O  D  E     V  5${R}"
printf '%s\n' "${D}   Holistic Yield & Validation Engines${R}"
printf '\n'
printf '   %sSYSTEMS ONLINE%s — %s\n' "$B" "$R" "$STATUS_LINE"
# OSC 8 hyperlink (terminals without support show the plain label)
printf '   %sby ISYNCSO · \033]8;;https://github.com/frogody/superboost-v5\033\\github.com/frogody/superboost-v5\033]8;;\033\\%s\n' "$D" "$R"
exit 0
