#!/bin/bash
set -e

# Auto-detect LibreChat source
SRC=$(find "$HOME/Documents" -maxdepth 5 -type d -name "LibreChat" 2>/dev/null | head -1)
if [ -z "$SRC" ]; then
    echo "ABORT: Could not find LibreChat under ~/Documents."
    exit 1
fi

DEST="$HOME/DocsLocal/LibreChat"
SESSION_FILE="$HOME/Library/Application Support/Claude/claude-code-sessions/1540220d-0573-4ef1-b8c9-8154e4e250ea/1eed8875-1eba-4cea-be7f-0a052a362125/local_4e427008-833e-4e08-a2d7-2e55ec995f61.json"
OLD_PROJ="$HOME/.claude/projects/-Users-rob-dev-Documents-GitHub-LibreChat"
NEW_PROJ="$HOME/.claude/projects/-Users-rob-dev-DocsLocal-LibreChat"
OUT="$HOME/DocsLocal/orbstack-search/fix-results.txt"

log() { echo "$1" | tee -a "$OUT"; }

echo "" > "$OUT"
log "=== LibreChat Session Repair: $(date) ==="
log ""

# ── Pre-flight ──────────────────────────────────────────
log "[1/4] Pre-flight checks"

if pgrep -x -u "$USER" "Claude" > /dev/null 2>&1; then
    log "  ABORT: Claude Desktop is running. Quit it first (Cmd+Q)."
    exit 1
fi
log "  ✓ Claude Desktop not running"

[ -d "$SRC" ]          && log "  ✓ Source: $SRC" \
                        || { log "  ABORT: Source missing: $SRC"; exit 1; }
[ ! -f "$SESSION_FILE" ] && { log "  ABORT: Session file missing"; exit 1; } \
                        || log "  ✓ Session metadata found"

# Auto-detect CLI history path
if [ ! -d "$OLD_PROJ" ]; then
    ACTUAL_PROJ=$(find "$HOME/.claude/projects/" -maxdepth 1 -type d -name "*LibreChat*" 2>/dev/null | head -1)
    if [ -n "$ACTUAL_PROJ" ]; then
        OLD_PROJ="$ACTUAL_PROJ"
        BASENAME=$(basename "$ACTUAL_PROJ")
        NEW_PROJ="$HOME/.claude/projects/$(echo "$BASENAME" | sed 's|-Documents.*GitHub-LibreChat|-DocsLocal-LibreChat|')"
    fi
fi
[ -d "$OLD_PROJ" ] && log "  ✓ CLI history found" \
                   || log "  - CLI history not found (will skip)"

# If destination exists from a previous interrupted run, rsync will resume
if [ -d "$DEST" ]; then
    log "  Partial copy found from previous run — rsync will resume"
fi

log ""

# ── Step 1: Copy project ───────────────────────────────
SRC_COUNT=$(find "$SRC" -type f | wc -l | tr -d ' ')
SRC_SIZE=$(du -sh "$SRC" | cut -f1)
log "[2/4] Copying LibreChat ($SRC_SIZE, $SRC_COUNT files)"

# rsync resumes from partial copy; no --progress flag (kills performance on small files)
log "  Copying..."
rsync -a "$SRC/" "$DEST/"

# Verify
DEST_COUNT=$(find "$DEST" -type f | wc -l | tr -d ' ')
DEST_SIZE=$(du -sh "$DEST" | cut -f1)
if [ "$SRC_COUNT" != "$DEST_COUNT" ]; then
    log "  ABORT: File count mismatch (src=$SRC_COUNT, dest=$DEST_COUNT). Metadata not touched."
    exit 1
fi
log "  ✓ Copied and verified ($DEST_SIZE, $DEST_COUNT files)"
log ""

# ── Step 2: Update session metadata ───────────────────
log "[3/4] Updating session metadata"
cp "$SESSION_FILE" "${SESSION_FILE}.bak"

PYTHON_OUTPUT=$(python3 - "$SESSION_FILE" "$DEST" << 'PYEOF'
import json, sys

session_file = sys.argv[1]
new_path = sys.argv[2]

with open(session_file) as f:
    data = json.load(f)

old_cwd = data.get('cwd', '')
data['cwd'] = new_path
data['originCwd'] = new_path

with open(session_file, 'w') as f:
    json.dump(data, f, indent=2)

# Verify
with open(session_file) as f:
    verify = json.load(f)
assert verify['cwd'] == new_path, f"cwd verify failed: {verify['cwd']}"
assert verify['originCwd'] == new_path, f"originCwd verify failed: {verify['originCwd']}"

print(f'  {old_cwd}')
print(f'  -> {new_path}')
PYEOF
) || {
    log "  ERROR: Update failed — restoring backup"
    cp "${SESSION_FILE}.bak" "$SESSION_FILE"
    exit 1
}
log "$PYTHON_OUTPUT"
log "  ✓ Metadata updated (backup at .bak)"
log ""

# ── Step 3: Copy CLI history ──────────────────────────
log "[4/4] CLI project history"
if [ -d "$OLD_PROJ" ]; then
    if [ -d "$NEW_PROJ" ]; then
        log "  ✓ Already exists at new path (skipped)"
    else
        cp -a "$OLD_PROJ" "$NEW_PROJ"
        log "  ✓ Copied to new path"
    fi
else
    log "  - Skipped (not found)"
fi
log ""

# ── Done ──────────────────────────────────────────────
log "Done. Originals preserved — nothing deleted."
log ""
log "Next: relaunch Claude Desktop and check 'Clone LibreChat repository' loads."
log "Full log: $OUT"
