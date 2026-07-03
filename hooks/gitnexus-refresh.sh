#!/bin/bash
# gitnexus-refresh.sh — SessionStart hook: report GitNexus index freshness (Superboost v3.1)
# v3.1 changes vs v3.0:
#   - CWD GUARD: only act when the session is actually inside the target repo. v3.0 ran
#     on EVERY session in every directory, statting an unrelated path and emitting noise.
#   - NO AUTO-EXEC: v3.0 ran `npx gitnexus analyze` (network + compute + supply-chain
#     surface) automatically on a stale index. v3.1 only REPORTS staleness; you run the
#     analyze yourself. A SessionStart hook must never silently fetch/run remote code.
#   - REPO_DIR overridable via env.

REPO_DIR="${GITNEXUS_REPO_DIR:-$HOME/app.isyncso}"
META="$REPO_DIR/.gitnexus/meta.json"

# CWD guard: no-op silently unless this session is inside the target repo.
case "$PWD/" in
  "$REPO_DIR/"*) : ;;
  *) exit 0 ;;
esac

[ -d "$REPO_DIR/.gitnexus" ] || { echo "GitNexus: no index at $REPO_DIR. Run 'npx gitnexus analyze' to create one."; exit 0; }

CURRENT_COMMIT=$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null)
[ -z "$CURRENT_COMMIT" ] && { echo "GitNexus: could not read git HEAD. Skipping."; exit 0; }

INDEXED_COMMIT=$(python3 -c "import json; print(json.load(open('$META'))['lastCommit'])" 2>/dev/null)

if [ "$CURRENT_COMMIT" = "$INDEXED_COMMIT" ]; then
  STATS=$(python3 -c "
import json
m = json.load(open('$META')); s = m['stats']
print(f\"GitNexus index is FRESH (indexed at {m['indexedAt'][:19]})\")
print(f\"Symbols: {s['nodes']} | Relationships: {s['edges']} | Flows: {s['processes']} | Files: {s['files']}\")
" 2>/dev/null)
  echo "GITNEXUS SESSION CONTEXT — $STATS"
  echo "Use gitnexus_query, gitnexus_context, gitnexus_impact to understand code before editing."
else
  COMMITS_BEHIND=$(git -C "$REPO_DIR" rev-list --count "$INDEXED_COMMIT".."$CURRENT_COMMIT" 2>/dev/null || echo "unknown")
  echo "GitNexus: index is $COMMITS_BEHIND commit(s) behind HEAD — run 'npx gitnexus analyze' in $REPO_DIR to refresh."
fi

exit 0
