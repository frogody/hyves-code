#!/bin/bash
# gitnexus-refresh.sh — SessionStart hook to ensure GitNexus index is fresh
# Runs at the start of every Claude Code session.
# If the repo has new commits since the last index, re-analyzes.
# If already fresh, outputs a summary of the index for Claude's context.

REPO_DIR="$HOME/app.isyncso"
META="$REPO_DIR/.gitnexus/meta.json"

# Check if we're in the right repo
if [ ! -d "$REPO_DIR/.gitnexus" ]; then
  echo "GitNexus: No index found at $REPO_DIR. Run 'npx gitnexus analyze' to create one."
  exit 0
fi

# Get current HEAD commit
CURRENT_COMMIT=$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null)
if [ -z "$CURRENT_COMMIT" ]; then
  echo "GitNexus: Could not read git HEAD. Skipping refresh."
  exit 0
fi

# Get last indexed commit from meta.json
INDEXED_COMMIT=$(python3 -c "import json; print(json.load(open('$META'))['lastCommit'])" 2>/dev/null)

# Compare
if [ "$CURRENT_COMMIT" = "$INDEXED_COMMIT" ]; then
  # Index is fresh — output summary for Claude's context
  STATS=$(python3 -c "
import json
m = json.load(open('$META'))
s = m['stats']
print(f\"GitNexus index is FRESH (indexed at {m['indexedAt'][:19]})\")
print(f\"Symbols: {s['nodes']} | Relationships: {s['edges']} | Flows: {s['processes']} | Files: {s['files']}\")
" 2>/dev/null)
  echo "GITNEXUS SESSION CONTEXT — $STATS"
  echo "Use gitnexus_query, gitnexus_context, gitnexus_impact tools to understand code before editing."
else
  # Index is stale — refresh
  COMMITS_BEHIND=$(git -C "$REPO_DIR" rev-list --count "$INDEXED_COMMIT".."$CURRENT_COMMIT" 2>/dev/null || echo "unknown")
  echo "GitNexus: Index is $COMMITS_BEHIND commit(s) behind HEAD. Refreshing..."

  # Run analyze (no embeddings since stats show 0)
  cd "$REPO_DIR" && npx gitnexus analyze 2>&1 | tail -3

  # Output updated stats
  if [ -f "$META" ]; then
    STATS=$(python3 -c "
import json
m = json.load(open('$META'))
s = m['stats']
print(f\"GitNexus index REFRESHED (indexed at {m['indexedAt'][:19]})\")
print(f\"Symbols: {s['nodes']} | Relationships: {s['edges']} | Flows: {s['processes']} | Files: {s['files']}\")
" 2>/dev/null)
    echo "GITNEXUS SESSION CONTEXT — $STATS"
  fi
  echo "Use gitnexus_query, gitnexus_context, gitnexus_impact tools to understand code before editing."
fi

exit 0
