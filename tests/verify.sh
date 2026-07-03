#!/bin/bash
# verify.sh — Superboost quick regression suite (~15s, deterministic).
# Deep animation capture lives in fxcap.py / ansi2json.py (run separately).
# Exit 0 = all pass.

HOOKS="$HOME/.claude/hooks"
TESTS="$HOME/.claude/tests"
SL="$HOOKS/superboost-statusline.sh"
FX="$HOOKS/superboost-fx.sh"
STATE="${SUPERBOOST_FX_DIR:-$HOME/.claude/fx}/state"
FAILS=0
t()  { if eval "$2" >/dev/null 2>&1; then echo "  ok   $1"; else echo "  FAIL $1"; FAILS=$((FAILS+1)); fi; }
say() { echo; echo "== $1 =="; }

say "hook syntax"
for f in "$HOOKS"/*.sh; do
  bash -n "$f" 2>/dev/null || { echo "  FAIL syntax: $f"; FAILS=$((FAILS+1)); }
done
echo "  ok   bash -n on all hooks"

say "settings bindings"
S="$HOME/.claude/settings.json"
t "settings.json valid JSON"      "python3 -c 'import json;json.load(open(\"$S\"))'"
for b in superboost-banner safety-guard resource-guard ram-monitor superboost-fx superboost-statusline "parallelism.sh --turn" "emit done" "superboost-fx.sh clear"; do
  t "binding: $b" "grep -qF -- '$b' '$S'"
done

say "banner self-test"
LINE="$("$HOOKS/superboost-banner.sh" 2>/dev/null | head -1)"
case "$LINE" in *"boot OK"*) echo "  ok   ${LINE%%. Do NOT*}" ;; *) echo "  FAIL banner: $LINE"; FAILS=$((FAILS+1)) ;; esac

say "safety-guard matrix"
python3 "$TESTS/guard-test.py" | tail -1
python3 "$TESTS/guard-test.py" >/dev/null 2>&1 || FAILS=$((FAILS+1))

say "statusline width + behavior"
RICH='{"model":{"display_name":"Fable 5"},"cost":{"total_cost_usd":4.56,"total_lines_added":12,"total_lines_removed":3},"context_window":{"used_percentage":42.5},"rate_limits":{"five_hour":{"used_percentage":10}},"effort":{"level":"xhigh"},"workspace":{"current_dir":"/tmp/proj"}}'
for W in 200 160 140 120 60; do
  LEN=$(echo "$RICH" | COLUMNS=$W "$SL" | perl -pe 's/\e\[[0-9;]*m//g' | awk '{print length($0)}')
  if [ "$LEN" -le $((W-5)) ] && [ "$LEN" -ge 40 ]; then echo "  ok   COLUMNS=$W -> $LEN"; else echo "  FAIL COLUMNS=$W -> $LEN"; FAILS=$((FAILS+1)); fi
done
t "fractional ctx% renders green"  "echo '$RICH' | COLUMNS=160 '$SL' | grep -qF '38;2;34;197;94m ctx 42.5%'"
t "plain mode branded"             "echo '$RICH' | SUPERBOOST_STATUSLINE_PLAIN=1 '$SL' | grep -qF 'HYVES CODE V5 |'"
t "empty stdin no crash"           "echo '' | COLUMNS=120 '$SL'"
# v5.2.1: the FX canvas must be a real stage (>=18 cells) at common widths —
# measured before the fix: 9 cells at COLUMNS=150 turned scanner motion to mush.
# In plain text the canvas is the space-run just left of the label: >=20 incl.
# the cap chip's trailing + label's leading pad.
"$FX" emit fanout; CVOK=0
echo "$RICH" | COLUMNS=150 "$SL" | perl -pe 's/\e\[[0-9;]*m//g' | grep -Eq ' {20,}FAN-OUT' && CVOK=1
"$FX" clear
t "canvas floor >=18 at COLUMNS=150" "[ $CVOK = 1 ]"

say "fx classification"
fxcase() { echo "$2" | "$FX"; head -1 "$STATE" 2>/dev/null | grep -q "^$1|"; }
t "npm test ok -> pass"    "fxcase pass   '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"npm test\"},\"tool_response\":{\"exit_code\":0}}'"
t "pytest rc=1 -> fail"    "fxcase fail   '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"pytest\"},\"tool_response\":{\"exit_code\":1}}'"
t "npm run deploy -> deploy" "fxcase deploy '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"npm run deploy\"},\"tool_response\":{\"exit_code\":0}}'"
t "git commit -> commit"   "fxcase commit '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m x\"}}'"
t "Agent -> fanout"        "fxcase fanout '{\"tool_name\":\"Agent\",\"tool_input\":{\"prompt\":\"x\"}}'"
"$FX" emit commit; BEFORE=$(cat "$STATE")
echo '{"tool_name":"Read","tool_input":{"file_path":"/tmp/x"}}' | "$FX"
t "Read leaves state alone" "[ \"\$(cat '$STATE')\" = '$BEFORE' ]"
# v5.2.1: emit time must be a FLOAT epoch (int truncation started sweep/scanner
# phases up to 1s late)
t "fx emits float epoch"    "awk -F'|' 'NR==1{exit (\$6 ~ /^[0-9]+\.[0-9]+$/) ? 0 : 1}' '$STATE'"
"$FX" clear

say "live budget --turn gating"
P="$HOOKS/superboost-parallelism.sh"
"$P" --line >/dev/null 2>&1   # seed stash
t "--turn silent when unchanged" "[ -z \"\$('$P' --turn)\" ]"
echo solo > "${SUPERBOOST_FX_DIR:-$HOME/.claude/fx}/budget_mode"
t "--turn speaks on mode flip"   "'$P' --turn | grep -q 'CHANGED'"
t "--turn silent again"          "[ -z \"\$('$P' --turn)\" ]"

say "hyves-boot"
t "non-TTY plain fallback"  "'$HOOKS/hyves-boot.sh' | grep -q 'HYVES CODE V5'"
t "PTY run exits 0"         "HYVES_BOOT_FRAMES=6 script -q /dev/null '$HOOKS/hyves-boot.sh' >/dev/null"

echo
if [ "$FAILS" -eq 0 ]; then echo "VERIFY: ALL PASS"; else echo "VERIFY: $FAILS FAILURE(S)"; fi
exit $((FAILS > 0))
