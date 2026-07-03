#!/bin/bash
# superboost-secrets.sh — keychain-backed credential manager + first-boot provisioning
# Part of Claude Code Superboost v4 by ISYNCSO (https://isyncso.com)
#
# User-specific credentials (tokens/keys) are stored ONCE in the macOS keychain
# (Linux: a 0600 file fallback) and reused by every subsequent session. On first
# boot, if a REQUIRED credential is missing, `check` emits a setup instruction so
# Claude asks the user for it; once stored, sessions never prompt again.
#
# Values NEVER live in any file that is loaded into model context. The manifest
# ($HOME/.claude/superboost-secrets.json) lists credential SLOTS (names/services),
# not values, and is git-ignored.
#
# Usage:
#   superboost-secrets.sh check                 # SessionStart: report missing required creds
#   superboost-secrets.sh list                  # human: show slots + present/missing
#   superboost-secrets.sh get  <name>           # print stored value (for use in a command)
#   superboost-secrets.sh set  <name> [value]   # store/update (omit value => hidden prompt / stdin)
#   superboost-secrets.sh manifest              # show manifest path + contents

MANIFEST="${SUPERBOOST_SECRETS_MANIFEST:-$HOME/.claude/superboost-secrets.json}"
FALLBACK_DIR="$HOME/.claude/.secrets"   # used only when `security` (keychain) is unavailable

# Create an EMPTY default manifest on first run (public-safe; user adds slots).
if [ ! -f "$MANIFEST" ]; then
  cat > "$MANIFEST" <<'JSON'
{
  "_comment": "Superboost credential slots. VALUES live in the macOS keychain, not here. Add an entry per credential Superboost should provision on first boot.",
  "_example": {"name": "my-api-key", "service": "myapp-api-key", "env": "MY_API_KEY", "required": true, "description": "what it is / where it's used"},
  "credentials": []
}
JSON
  chmod 600 "$MANIFEST" 2>/dev/null
fi

resolve_service() {  # name-or-service -> keychain service string
  python3 -c '
import json, sys
mf, name = sys.argv[1], sys.argv[2]
try:
    creds = json.load(open(mf)).get("credentials", [])
except Exception:
    creds = []
for c in creds:
    if c.get("name") == name or c.get("service") == name:
        print(c.get("service", name)); break
else:
    print(name)
' "$MANIFEST" "$1"
}

kc_get() {  # service -> value on stdout (empty if absent)
  if command -v security >/dev/null 2>&1; then
    security find-generic-password -s "$1" -w 2>/dev/null
  else
    cat "$FALLBACK_DIR/$1" 2>/dev/null
  fi
}

kc_set() {  # service value
  if command -v security >/dev/null 2>&1; then
    security add-generic-password -U -a "${USER:-claude}" -s "$1" -w "$2" >/dev/null 2>&1
  else
    mkdir -p "$FALLBACK_DIR"; chmod 700 "$FALLBACK_DIR" 2>/dev/null
    printf '%s' "$2" > "$FALLBACK_DIR/$1"; chmod 600 "$FALLBACK_DIR/$1" 2>/dev/null
  fi
}

CMD="${1:-check}"
case "$CMD" in
  get)
    [ -z "$2" ] && { echo "usage: superboost-secrets.sh get <name>" >&2; exit 1; }
    kc_get "$(resolve_service "$2")"
    ;;

  set)
    [ -z "$2" ] && { echo "usage: superboost-secrets.sh set <name> [value]" >&2; exit 1; }
    NAME="$2"; VALUE="$3"
    if [ -z "$VALUE" ]; then
      if [ -t 0 ]; then read -r -s -p "Value for '$NAME' (hidden): " VALUE; echo; else VALUE="$(cat)"; fi
    fi
    [ -z "$VALUE" ] && { echo "no value provided; nothing stored." >&2; exit 1; }
    SVC="$(resolve_service "$NAME")"
    kc_set "$SVC" "$VALUE" && echo "stored '$NAME' -> keychain service '$SVC'."
    ;;

  list)
    python3 - "$MANIFEST" <<'PY'
import json, sys, subprocess, shutil, os
try:
    creds = json.load(open(sys.argv[1])).get("credentials", [])
except Exception:
    creds = []
have = shutil.which("security")
def present(svc):
    if have:
        return subprocess.run(["security","find-generic-password","-s",svc,"-w"],
                              capture_output=True).returncode == 0
    return os.path.exists(os.path.expanduser("~/.claude/.secrets/"+svc))
if not creds:
    print("  (no credential slots configured — edit ~/.claude/superboost-secrets.json)")
for c in creds:
    ok = present(c["service"])
    req = "required" if c.get("required") else "optional"
    print(f"  [{'set' if ok else 'MISSING'}] {c['name']} ({req}) -> keychain '{c['service']}'  - {c.get('description','')}")
PY
    ;;

  check)
    MISSING="$(python3 - "$MANIFEST" <<'PY'
import json, sys, subprocess, shutil, os
try:
    creds = json.load(open(sys.argv[1])).get("credentials", [])
except Exception:
    creds = []
have = shutil.which("security")
def present(svc):
    if have:
        return subprocess.run(["security","find-generic-password","-s",svc,"-w"],
                              capture_output=True).returncode == 0
    return os.path.exists(os.path.expanduser("~/.claude/.secrets/"+svc))
for c in creds:
    if c.get("required") and not present(c["service"]):
        print(f"{c['name']}|{c.get('description','')}")
PY
)"
    if [ -n "$MISSING" ]; then
      echo "SUPERBOOST FIRST-BOOT SETUP — required credentials are not yet stored. Ask the user for each value below (a single prompt is fine), then store each WITHOUT writing it to any file:"
      echo "$MISSING" | while IFS='|' read -r n d; do
        [ -n "$n" ] && echo "  - ${n}: ${d}"
      done
      echo "Store via (value goes straight to the macOS keychain):  ~/.claude/hooks/superboost-secrets.sh set <name> <value>"
      echo "For maximum safety the user may instead run it themselves with a hidden prompt:  ~/.claude/hooks/superboost-secrets.sh set <name>"
      echo "Verify afterwards with:  ~/.claude/hooks/superboost-secrets.sh list"
    fi
    exit 0
    ;;

  manifest) echo "$MANIFEST"; echo "---"; cat "$MANIFEST" ;;
  *) echo "usage: superboost-secrets.sh {check|list|get <name>|set <name> [value]|manifest}" >&2; exit 1 ;;
esac
