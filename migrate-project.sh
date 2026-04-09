#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════
# migrate-project.sh — Safely migrate a project from ~/Documents (iCloud)
#                       to ~/DocsLocal, updating AI tool session metadata.
#
# BACKGROUND
# macOS Migration Assistant creates a nested subdirectory under ~/Documents
# named "Documents - <OldMacName>" (with a Unicode curly-quote U+2019 in
# the possessive). If ~/Documents syncs to iCloud Drive, projects with
# node_modules, Docker data, and git repos waste bandwidth and break tools
# that store absolute paths.
#
# TOOL IMPACT
#   Claude Code Desktop — cwd/originCwd in session JSON. Script updates these.
#   Claude Code CLI     — project history in ~/.claude/projects/. Script copies.
#   Claude Co-work      — userSelectedFolders in session JSON. Script updates these.
#   Codex (OpenAI)      — cwd in session_meta inside JSONL. Script updates the
#                         session_meta line only; conversation content untouched.
#   claude.ai           — server-side only, unaffected.
#
# USAGE
#   bash migrate-project.sh <project-name>
#
# OPTIONS
#   --dry-run     Show what would happen without making changes
#   --force       Skip confirmation prompt
#
# EXAMPLES
#   bash migrate-project.sh LibreChat
#   bash migrate-project.sh "Obsidian Vault"
#   bash migrate-project.sh --dry-run Projects
# ═══════════════════════════════════════════════════════════════════════
set -e

# ── Parse arguments ───────────────────────────────────────
DRY_RUN=false
FORCE=false
PROJECT_NAME=""

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --force)   FORCE=true ;;
        *)         PROJECT_NAME="$arg" ;;
    esac
done

if [ -z "$PROJECT_NAME" ]; then
    echo "Usage: bash migrate-project.sh [--dry-run] [--force] <project-name>"
    echo ""
    echo "Migrates a project from ~/Documents to ~/DocsLocal, updating"
    echo "Claude Code session metadata."
    echo ""
    echo "Options:"
    echo "  --dry-run   Show what would happen without making changes"
    echo "  --force     Skip confirmation prompt"
    exit 1
fi

DEST_BASE="$HOME/DocsLocal"
SESSIONS_DIR="$HOME/Library/Application Support/Claude/claude-code-sessions"
COWORK_DIR="$HOME/Library/Application Support/Claude/local-agent-mode-sessions"
CLI_PROJECTS="$HOME/.claude/projects"
CODEX_SESSIONS="$HOME/.codex/sessions"
OUT="$DEST_BASE/orbstack-search/migrate-${PROJECT_NAME//[^a-zA-Z0-9_-]/_}.log"

log() { echo "$1" | tee -a "$OUT"; }
die() { log "  ABORT: $1"; exit 1; }
warn() { log "  ⚠ $1"; }

mkdir -p "$(dirname "$OUT")"
echo "" > "$OUT"
log "═══ Project Migration: $PROJECT_NAME ═══"
log "    $(date)"
if [ "$DRY_RUN" = true ]; then
    log "    *** DRY RUN — no changes will be made ***"
fi
log ""

# ── 1. Pre-flight ────────────────────────────────────────
log "[1/8] Pre-flight checks"

# Claude Desktop must not be running (current user only)
if pgrep -x -u "$USER" "Claude" > /dev/null 2>&1; then
    die "Claude Desktop is running. Quit it first (Cmd+Q)."
fi
log "  ✓ Claude Desktop not running"

# Find the project — search all of ~/Documents, handle Unicode names
SRC_CANDIDATES=$(find "$HOME/Documents" -maxdepth 5 -type d -name "$PROJECT_NAME" 2>/dev/null)
SRC_COUNT_FOUND=$(echo "$SRC_CANDIDATES" | grep -c . 2>/dev/null || echo 0)
if [ "$SRC_COUNT_FOUND" -eq 0 ] || [ -z "$SRC_CANDIDATES" ]; then
    die "Could not find '$PROJECT_NAME' under ~/Documents"
elif [ "$SRC_COUNT_FOUND" -gt 1 ]; then
    log "  ⚠ Multiple directories named '$PROJECT_NAME' found:"
    echo "$SRC_CANDIDATES" | while read -r c; do log "      $c"; done
    die "Ambiguous project name. Use a more specific name or rename one of the directories."
fi
SRC="$SRC_CANDIDATES"
[ -d "$SRC" ] || die "Source is not a directory: $SRC"
log "  ✓ Source: $SRC"

DEST="$DEST_BASE/$PROJECT_NAME"

# Validate destination stays within DEST_BASE (prevent path traversal)
DEST_REAL=$(mkdir -p "$DEST" && cd "$DEST" && pwd)
DEST_BASE_REAL=$(cd "$DEST_BASE" && pwd)
if [[ "$DEST_REAL" != "$DEST_BASE_REAL"/* ]]; then
    rmdir "$DEST" 2>/dev/null  # clean up if we just created it
    die "Destination '$DEST' resolves outside of $DEST_BASE (path traversal). Aborting."
fi

# Check destination
if [ -d "$DEST" ]; then
    log "  ⟳ Destination exists (rsync will resume/update)"
else
    log "  ✓ Destination clear: $DEST"
fi

# Check disk space
SRC_KB=$(du -sk "$SRC" | cut -f1)
AVAIL_KB=$(df -k "$DEST_BASE" | tail -1 | awk '{print $4}')
if [ "$SRC_KB" -gt "$AVAIL_KB" ]; then
    SRC_H=$(du -sh "$SRC" | cut -f1)
    AVAIL_H=$(df -h "$DEST_BASE" | tail -1 | awk '{print $4}')
    die "Not enough disk space (need ~$SRC_H, have $AVAIL_H free)"
fi
log "  ✓ Disk space OK"
log ""

# ── 2. Detect tool references ───────────────────────────
log "[2/8] Scanning for AI tool references to this project"

# Claude Code path encoding: / → - and _ → -
encode_path() {
    echo "$1" | sed 's|^/|-|' | sed 's|/|-|g' | sed 's|_|-|g'
}

HAS_DESKTOP=false
HAS_CLI=false
HAS_CODEX=false
HAS_COWORK=false

# Claude Code Desktop sessions
# Search for project name in cwd fields; matches are verified by Python before updating
MATCHING_SESSIONS=()
if [ -d "$SESSIONS_DIR" ]; then
    while IFS= read -r f; do
        MATCHING_SESSIONS+=("$f")
    done < <(grep -Frl "/$PROJECT_NAME\"" "$SESSIONS_DIR" 2>/dev/null || true)
fi
if [ ${#MATCHING_SESSIONS[@]} -gt 0 ]; then
    HAS_DESKTOP=true
    log "  Claude Code Desktop: ${#MATCHING_SESSIONS[@]} session(s) — will update cwd"
else
    log "  Claude Code Desktop: no sessions reference this project"
fi

# Claude Code CLI history
CLI_MATCHES=()
if [ -d "$CLI_PROJECTS" ]; then
    while IFS= read -r d; do
        CLI_MATCHES+=("$d")
    done < <(find "$CLI_PROJECTS" -maxdepth 1 -type d -name "*${PROJECT_NAME}*" 2>/dev/null || true)
fi
if [ ${#CLI_MATCHES[@]} -gt 0 ]; then
    HAS_CLI=true
    log "  Claude Code CLI:     ${#CLI_MATCHES[@]} history dir(s) — will copy to new path"
else
    log "  Claude Code CLI:     no history found"
fi

# Codex sessions (check for cwd references in JSONL)
CODEX_MATCHES=()
if [ -d "$CODEX_SESSIONS" ]; then
    while IFS= read -r f; do
        CODEX_MATCHES+=("$f")
    done < <(grep -Frl "/$PROJECT_NAME\"" "$CODEX_SESSIONS" 2>/dev/null || true)
fi
if [ ${#CODEX_MATCHES[@]} -gt 0 ]; then
    HAS_CODEX=true
    log "  Codex:               ${#CODEX_MATCHES[@]} session(s) — will update session_meta cwd"
else
    log "  Codex:               no sessions reference this project"
fi

# Co-work sessions (check userSelectedFolders in session JSON)
COWORK_SESSIONS=()
if [ -d "$COWORK_DIR" ]; then
    while IFS= read -r f; do
        COWORK_SESSIONS+=("$f")
    done < <(grep -Frl "$PROJECT_NAME" "$COWORK_DIR" 2>/dev/null || true)
fi
if [ ${#COWORK_SESSIONS[@]} -gt 0 ]; then
    HAS_COWORK=true
    log "  Co-work:             ${#COWORK_SESSIONS[@]} session(s) — will update userSelectedFolders"
else
    log "  Co-work:             no sessions reference this project"
fi

# Summary of what will/won't be updated
if [ "$HAS_DESKTOP" = false ] && [ "$HAS_CLI" = false ] && [ "$HAS_COWORK" = false ] && [ "$HAS_CODEX" = false ]; then
    warn "No Claude Code Desktop, CLI, Co-work, or Codex references found."
    log "       The copy will still proceed, but no session metadata needs updating."
    log "       This project may not have been used with Claude Code."
fi

log ""

# ── 3. Confirmation ─────────────────────────────────────
if [ "$DRY_RUN" = true ]; then
    log "[DRY RUN] Would copy:"
    SRC_SIZE=$(du -sh "$SRC" | cut -f1)
    SRC_COUNT=$(find "$SRC" -type f | wc -l | tr -d ' ')
    log "  $SRC ($SRC_SIZE, $SRC_COUNT files)"
    log "  → $DEST"
    [ "$HAS_DESKTOP" = true ] && log "  Would update ${#MATCHING_SESSIONS[@]} Desktop session(s)"
    [ "$HAS_CLI" = true ]     && log "  Would copy ${#CLI_MATCHES[@]} CLI history dir(s)"
    [ "$HAS_COWORK" = true ]  && log "  Would update ${#COWORK_SESSIONS[@]} Co-work session(s)"
    [ "$HAS_CODEX" = true ]   && log "  Would update ${#CODEX_MATCHES[@]} Codex session(s)"
    log ""
    log "Run without --dry-run to proceed."
    exit 0
fi

if [ "$FORCE" = false ]; then
    SRC_SIZE=$(du -sh "$SRC" | cut -f1)
    echo ""
    echo "  Will copy: $SRC ($SRC_SIZE)"
    echo "        To:  $DEST"
    [ "$HAS_DESKTOP" = true ] && echo "  Will update ${#MATCHING_SESSIONS[@]} Desktop session(s)"
    [ "$HAS_CLI" = true ]     && echo "  Will copy ${#CLI_MATCHES[@]} CLI history dir(s)"
    [ "$HAS_COWORK" = true ]  && echo "  Will update ${#COWORK_SESSIONS[@]} Co-work session(s)"
    [ "$HAS_CODEX" = true ]   && echo "  Will update ${#CODEX_MATCHES[@]} Codex session(s)"
    echo ""
    read -p "  Proceed? [y/N] " CONFIRM
    if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
        log "  Cancelled by user."
        exit 0
    fi
fi

# ── 4. Copy ──────────────────────────────────────────────
SRC_COUNT=$(find "$SRC" -type f | wc -l | tr -d ' ')
SRC_SIZE=$(du -sh "$SRC" | cut -f1)
log "[3/8] Copying $PROJECT_NAME ($SRC_SIZE, $SRC_COUNT files)"
log "  Copying..."

RSYNC_EXIT=0
rsync -a "$SRC/" "$DEST/" || RSYNC_EXIT=$?
if [ "$RSYNC_EXIT" -ne 0 ]; then
    die "rsync failed (exit $RSYNC_EXIT). Partial copy may exist at $DEST. Metadata not touched."
fi

# Verify
DEST_COUNT=$(find "$DEST" -type f | wc -l | tr -d ' ')
DEST_SIZE=$(du -sh "$DEST" | cut -f1)
if [ "$SRC_COUNT" != "$DEST_COUNT" ]; then
    die "File count mismatch (src=$SRC_COUNT, dest=$DEST_COUNT). Metadata not touched."
fi
log "  ✓ Copied and verified ($DEST_SIZE, $DEST_COUNT files)"
log ""

# ── 5. Update session metadata ──────────────────────────
log "[4/8] Updating Claude Code Desktop sessions"

if [ ${#MATCHING_SESSIONS[@]} -eq 0 ]; then
    log "  - No sessions to update"
else
    for sf in "${MATCHING_SESSIONS[@]}"; do
        OLD_CWD=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
print(d.get('cwd', ''))
" "$sf" 2>/dev/null || echo "")

        if [ -z "$OLD_CWD" ]; then
            log "  - Skipping (could not read cwd): $sf"
            continue
        fi

        log "  $OLD_CWD → $DEST"

        # Backup
        cp "$sf" "${sf}.bak"

        # Update cwd and originCwd
        PYTHON_OUTPUT=$(python3 - "$sf" "$DEST" << 'PYEOF'
import json, sys

session_file = sys.argv[1]
new_path = sys.argv[2]

with open(session_file) as f:
    data = json.load(f)

data['cwd'] = new_path
data['originCwd'] = new_path

with open(session_file, 'w') as f:
    json.dump(data, f, indent=2)

# Verify
with open(session_file) as f:
    verify = json.load(f)
assert verify['cwd'] == new_path, f"cwd verify failed: {verify['cwd']}"
assert verify['originCwd'] == new_path, f"originCwd verify failed: {verify['originCwd']}"

print('    ✓ Verified')
PYEOF
        ) || {
            log "    ERROR: Update failed — restoring backup"
            cp "${sf}.bak" "$sf"
            continue
        }
        log "$PYTHON_OUTPUT"
    done
fi
log ""

# ── 6. Copy CLI history ─────────────────────────────────
log "[5/8] CLI project history"

if [ ${#CLI_MATCHES[@]} -eq 0 ]; then
    log "  - No CLI history to copy"
else
    for old_proj in "${CLI_MATCHES[@]}"; do
        NEW_ENCODED=$(encode_path "$DEST")
        NEW_PROJ="$CLI_PROJECTS/$NEW_ENCODED"

        if [ -d "$NEW_PROJ" ]; then
            log "  ✓ Already exists: $(basename "$NEW_PROJ") (skipped)"
        else
            cp -a "$old_proj" "$NEW_PROJ"
            log "  ✓ $(basename "$old_proj") → $(basename "$NEW_PROJ")"
        fi
    done
fi
log ""

# ── 6b. Update Co-work session metadata ──────────────────
log "[6/8] Co-work sessions"

if [ ${#COWORK_SESSIONS[@]} -eq 0 ]; then
    log "  - No sessions to update"
else
    for cf in "${COWORK_SESSIONS[@]}"; do
        TITLE=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
print(d.get('title', 'untitled'))
" "$cf" 2>/dev/null || echo "unknown")

        log "  Updating '$TITLE'"

        # Backup
        cp "$cf" "${cf}.bak"

        # Update userSelectedFolders: replace entries containing old SRC path with DEST
        PYTHON_OUTPUT=$(python3 - "$cf" "$SRC" "$DEST" << 'PYEOF'
import json, sys

session_file = sys.argv[1]
old_base = sys.argv[2]
new_base = sys.argv[3]

with open(session_file) as f:
    data = json.load(f)

folders = data.get('userSelectedFolders', [])
updated = []
changes = 0
for folder in folders:
    # Path-aware matching: folder must be old_base exactly, or start with old_base/
    if folder == old_base or folder.startswith(old_base + '/'):
        new_folder = new_base + folder[len(old_base):]
        updated.append(new_folder)
        changes += 1
        print(f'    {folder}')
        print(f'    -> {new_folder}')
    else:
        updated.append(folder)

data['userSelectedFolders'] = updated

with open(session_file, 'w') as f:
    json.dump(data, f, indent=2)

# Verify
with open(session_file) as f:
    verify = json.load(f)
assert verify['userSelectedFolders'] == updated

if changes > 0:
    print(f'    ✓ Updated {changes} folder path(s)')
else:
    print('    - No matching paths found in userSelectedFolders')
PYEOF
        ) || {
            log "    ERROR: Update failed — restoring backup"
            cp "${cf}.bak" "$cf"
            continue
        }
        log "$PYTHON_OUTPUT"
    done
fi
log ""

# ── 7. Update Codex session_meta cwd ─────────────────────
log "[7/8] Codex sessions"

if [ ${#CODEX_MATCHES[@]} -eq 0 ]; then
    log "  - No sessions to update"
else
    for cf in "${CODEX_MATCHES[@]}"; do
        log "  Updating: $(basename "$(dirname "$cf")")/$(basename "$cf")"

        # Backup
        cp "$cf" "${cf}.bak"

        # Rewrite only the session_meta line, preserve all other lines exactly
        PYTHON_OUTPUT=$(python3 - "$cf" "$DEST" << 'PYEOF'
import json, sys

jsonl_path = sys.argv[1]
new_cwd = sys.argv[2]

with open(jsonl_path, "r", encoding="utf-8", errors="replace") as f:
    lines = f.readlines()

updated = False
new_lines = []
invalid_count = 0
for line in lines:
    stripped = line.strip()
    if not stripped:
        new_lines.append(line)
        continue
    try:
        data = json.loads(stripped)
    except json.JSONDecodeError:
        invalid_count += 1
        new_lines.append(line)
        continue

    if data.get("type") == "session_meta":
        old_cwd = data.get("payload", {}).get("cwd", "")
        if "payload" in data and "cwd" in data["payload"]:
            data["payload"]["cwd"] = new_cwd
            new_lines.append(json.dumps(data) + "\n")
            updated = True
            print(f'    {old_cwd}')
            print(f'    -> {new_cwd}')
        else:
            new_lines.append(line)
    else:
        new_lines.append(line)

if invalid_count > 0:
    print(f'    ⚠ {invalid_count} invalid JSONL line(s) found (preserved as-is)')

if updated:
    with open(jsonl_path, "w", encoding="utf-8") as f:
        f.writelines(new_lines)

    # Verify: re-read and check
    with open(jsonl_path, "r", encoding="utf-8") as f:
        for vline in f:
            vline = vline.strip()
            if not vline:
                continue
            try:
                vdata = json.loads(vline)
            except json.JSONDecodeError:
                continue
            if vdata.get("type") == "session_meta":
                assert vdata["payload"]["cwd"] == new_cwd, \
                    f"Codex verify failed: {vdata['payload']['cwd']}"
                print('    ✓ Verified')
                break
else:
    print('    - No session_meta with cwd found')
PYEOF
        ) || {
            log "    ERROR: Update failed — restoring backup"
            cp "${cf}.bak" "$cf"
            continue
        }
        log "$PYTHON_OUTPUT"
    done
fi
log ""

# ── Summary ──────────────────────────────────────────────
log "[8/8] Summary"
log "  Copied:     $SRC"
log "         →    $DEST"
log "  Desktop:    ${#MATCHING_SESSIONS[@]} session(s) updated"
log "  CLI:        ${#CLI_MATCHES[@]} history dir(s) copied"
log "  Co-work:    ${#COWORK_SESSIONS[@]} session(s) updated"
log "  Codex:      ${#CODEX_MATCHES[@]} session(s) updated"
log "  Originals:  Preserved (nothing deleted)"
log ""
log "  Next steps:"
log "    1. Relaunch Claude Desktop"
log "    2. Verify sessions load correctly"
log "    3. Once confirmed, optionally delete originals:"
log "       rm -rf \"$SRC\""
log ""
log "  Full log: $OUT"
