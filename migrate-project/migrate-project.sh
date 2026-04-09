#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════
# migrate-project.sh — Safely migrate a project from ~/Documents (iCloud)
#                       to ~/DocsLocal, updating AI tool session metadata.
#
# THREE-PATH MODEL
# macOS Migration Assistant creates a nested subdirectory under ~/Documents
# named "Documents - <OldMacName>" (with a Unicode curly-quote U+2019 in
# the possessive). Finder presents a *merged view* of ~/Documents, so tools
# that open projects see a logical path without the Migration Assistant
# segment. This script must handle three distinct paths:
#
#   Physical path (SRC)     — where files actually live on disk.
#                             e.g. ~/Documents/Documents - TMD's MBP/Projects/TSC
#   Session path (SESSION)  — the logical path recorded in AI tool metadata.
#                             e.g. ~/Documents/Projects/TSC
#   Destination (DEST)      — where files are being moved to.
#                             e.g. ~/DocsLocal/TSC
#
# The script rsyncs from SRC, but matches and rewrites sessions from
# SESSION → DEST. If SRC is not under a Migration Assistant subdirectory,
# SESSION and SRC are the same.
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
set -euo pipefail

# ── Parse arguments ───────────────────────────────────────
DRY_RUN=false
FORCE=false
PROJECT_NAME=""

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --force)   FORCE=true ;;
        --*)       echo "  ABORT: Unknown option: $arg"; exit 1 ;;
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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST_BASE="$HOME/DocsLocal"
SESSIONS_DIR="$HOME/Library/Application Support/Claude/claude-code-sessions"
COWORK_DIR="$HOME/Library/Application Support/Claude/local-agent-mode-sessions"
CLI_PROJECTS="$HOME/.claude/projects"
CODEX_SESSIONS="$HOME/.codex/sessions"
OUT="$SCRIPT_DIR/migrate-${PROJECT_NAME//[^a-zA-Z0-9_-]/_}.log"

log() { echo "$1" | tee -a "$OUT"; }
die() { log "  ABORT: $1"; exit 1; }
warn() { log "  ⚠ $1"; }

# Track in-progress backup so we can restore on interruption
CURRENT_BACKUP=""
cleanup_on_signal() {
    if [ -n "$CURRENT_BACKUP" ] && [ -f "$CURRENT_BACKUP" ]; then
        cp "$CURRENT_BACKUP" "${CURRENT_BACKUP%.bak}"
        log "  Restored from backup after interruption: ${CURRENT_BACKUP%.bak}"
    fi
    exit 1
}
trap cleanup_on_signal INT TERM

mkdir -p "$(dirname "$OUT")"
echo "" > "$OUT"
log "═══ Project Migration: $PROJECT_NAME ═══"
log "    $(date)"
if [ "$DRY_RUN" = true ]; then
    log "    *** DRY RUN — no changes will be made ***"
fi
log ""

# ── Pre-flight ──────────────────────────────────────────
log "[1/8] Pre-flight checks"

# Claude Desktop must not be running (current user only)
# SKIP_PROCESS_CHECK=1 allows test suites to bypass this while Claude is open
if [ "${SKIP_PROCESS_CHECK:-}" != "1" ]; then
    if pgrep -x -u "$USER" "Claude" > /dev/null 2>&1; then
        die "Claude Desktop is running. Quit it first (Cmd+Q)."
    fi
    if pgrep -x -u "$USER" "codex" > /dev/null 2>&1; then
        warn "Codex appears to be running. Session updates may conflict."
    fi
    if pgrep -u "$USER" -f "claude.*--project" > /dev/null 2>&1; then
        warn "Claude Code CLI appears to be running. Session updates may conflict."
    fi
fi
log "  ✓ Process checks passed"

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
log "  ✓ Source (physical): $SRC"

# Compute the logical path that sessions reference.
# macOS Finder merges "Documents - <MacName>/" into ~/Documents/, so tools
# opened projects via the shorter path. Strip the Migration Assistant segment.
SESSION_PATH=$(python3 -c "
import sys, os
src = sys.argv[1]
docs = os.path.expanduser('~/Documents')
prefix = docs + '/Documents - '
if src.startswith(prefix):
    rest = src[len(prefix):]
    slash = rest.find('/')
    if slash >= 0:
        print(docs + '/' + rest[slash + 1:])
    else:
        print(src)
else:
    print(src)
" "$SRC")

if [ "$SESSION_PATH" != "$SRC" ]; then
    log "  ✓ Session path:      $SESSION_PATH"
    log "    (Finder merged view — sessions use this path, not the physical one)"
fi

DEST="$DEST_BASE/$PROJECT_NAME"

# Validate destination stays within DEST_BASE (prevent path traversal)
# Resolve both canonical paths without creating DEST (handles /tmp → /private/tmp etc.)
DEST_REAL=$(python3 -c "import os, sys; print(os.path.realpath(sys.argv[1]))" "$DEST")
DEST_BASE_REAL=$(python3 -c "import os, sys; print(os.path.realpath(sys.argv[1]))" "$DEST_BASE")
if [[ "$DEST_REAL" != "$DEST_BASE_REAL"/* ]]; then
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

# ── Detect tool references ──────────────────────────────
log "[2/8] Scanning for AI tool references to this project"

# Claude Code path encoding: / → - and _ → -
encode_path() {
    local p="${1/#\//-}"
    p="${p//\//-}"
    p="${p//_/-}"
    echo "$p"
}

HAS_DESKTOP=false
HAS_CLI=false
HAS_CODEX=false
HAS_COWORK=false

# Claude Code Desktop sessions
# Search for project name in cwd fields; matches are verified before updating
MATCHING_SESSIONS=()
if [ -d "$SESSIONS_DIR" ]; then
    while IFS= read -r f; do
        MATCHING_SESSIONS+=("$f")
    done < <(grep -Frl "/$PROJECT_NAME\"" "$SESSIONS_DIR" 2>/dev/null || true)
fi
if [ ${#MATCHING_SESSIONS[@]} -gt 0 ]; then
    HAS_DESKTOP=true
    log "  Claude Code Desktop: ${#MATCHING_SESSIONS[@]} session file(s) — will update cwd"
    # Show session titles for inventory
    for sf in "${MATCHING_SESSIONS[@]}"; do
        TITLE=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f: d = json.load(f)
print(d.get('title', 'untitled'))
" "$sf" 2>/dev/null || echo "unknown")
        log "    • $TITLE"
    done
else
    log "  Claude Code Desktop: no sessions reference this project"
fi

# Claude Code CLI history — match by exact encoded path using SESSION_PATH
# (CLI history was created when the tool opened the project via the logical path)
# CLI dir contains parent session(s), subagent JSONLs, and memory
CLI_MATCHES=()
if [ -d "$CLI_PROJECTS" ]; then
    OLD_CLI_ENCODED=$(encode_path "$SESSION_PATH")
    if [ -d "$CLI_PROJECTS/$OLD_CLI_ENCODED" ]; then
        CLI_MATCHES=("$CLI_PROJECTS/$OLD_CLI_ENCODED")
    fi
fi
if [ ${#CLI_MATCHES[@]} -gt 0 ]; then
    HAS_CLI=true
    CLI_DIR="${CLI_MATCHES[0]}"
    CLI_SESSIONS=$(find "$CLI_DIR" -maxdepth 1 -type d ! -name memory ! -path "$CLI_DIR" 2>/dev/null | wc -l | tr -d ' ')
    CLI_SUBAGENTS=$(find "$CLI_DIR" -name "*.jsonl" -path "*/subagents/*" 2>/dev/null | wc -l | tr -d ' ')
    CLI_HAS_MEMORY="no"
    [ -f "$CLI_DIR/memory/MEMORY.md" ] && CLI_HAS_MEMORY="yes"
    log "  Claude Code CLI:     will copy history dir to new encoded path"
    log "    • $CLI_SESSIONS parent session(s), $CLI_SUBAGENTS subagent JSONL(s), memory: $CLI_HAS_MEMORY"
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

# Co-work sessions (check userSelectedFolders for the session path)
# Use SESSION_PATH as grep pattern and --include to skip JSONL conversation logs
COWORK_SESSIONS=()
if [ -d "$COWORK_DIR" ]; then
    while IFS= read -r f; do
        COWORK_SESSIONS+=("$f")
    done < <(grep -Frl --include='*.json' "$SESSION_PATH" "$COWORK_DIR" 2>/dev/null || true)
fi
if [ ${#COWORK_SESSIONS[@]} -gt 0 ]; then
    HAS_COWORK=true
    log "  Co-work:             ${#COWORK_SESSIONS[@]} session(s) — will update userSelectedFolders"
    for cf in "${COWORK_SESSIONS[@]}"; do
        TITLE=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f: d = json.load(f)
print(d.get('title', 'untitled'))
" "$cf" 2>/dev/null || echo "unknown")
        log "    • $TITLE"
    done
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

# Compute source stats once (used by dry-run, confirmation, and copy)
SRC_COUNT=$(find "$SRC" -type f | wc -l | tr -d ' ')
SRC_SIZE=$(du -sh "$SRC" | cut -f1)

# ── Confirmation / dry-run ──────────────────────────────
if [ "$DRY_RUN" = true ]; then
    log "[DRY RUN] Would copy:"
    log "  $SRC ($SRC_SIZE, $SRC_COUNT files)"
    log "  → $DEST"
    if [ "$SESSION_PATH" != "$SRC" ]; then
        log "  Session metadata references: $SESSION_PATH"
    fi
    [ "$HAS_DESKTOP" = true ] && log "  Would update ${#MATCHING_SESSIONS[@]} Desktop session(s)"
    [ "$HAS_CLI" = true ]     && log "  Would copy ${#CLI_MATCHES[@]} CLI history dir(s)"
    [ "$HAS_COWORK" = true ]  && log "  Would update ${#COWORK_SESSIONS[@]} Co-work session(s)"
    [ "$HAS_CODEX" = true ]   && log "  Would update ${#CODEX_MATCHES[@]} Codex session(s)"
    log ""
    log "Run without --dry-run to proceed."
    exit 0
fi

if [ "$FORCE" = false ]; then
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

# ── Copy ────────────────────────────────────────────────
mkdir -p "$DEST"
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

# ── Shared Python helper for session metadata updates ───
# Defines rewrite() once; modes: check_cwd, desktop, cowork, codex
UPDATE_SESSION_PY=$(cat << 'PYEOF'
import json, sys

def rewrite(path, old_base, new_base):
    """Replace old_base prefix with new_base if path matches."""
    if path == old_base:
        return new_base
    elif path.startswith(old_base + '/'):
        return new_base + path[len(old_base):]
    return None

mode = sys.argv[1]
filepath = sys.argv[2]
old_base = sys.argv[3]
new_base = sys.argv[4]

if mode == 'check_cwd':
    # Read cwd from JSON; print it or empty string on error
    try:
        with open(filepath) as f:
            print(json.load(f).get('cwd', ''))
    except Exception:
        print('')

elif mode == 'desktop':
    with open(filepath) as f:
        data = json.load(f)
    new_path = rewrite(data.get('cwd', ''), old_base, new_base)
    if new_path is None:
        print(f'    - Skipping (cwd not under {old_base})')
        sys.exit(0)
    data['cwd'] = new_path
    data['originCwd'] = new_path
    with open(filepath, 'w') as f:
        json.dump(data, f, indent=2)
    with open(filepath) as f:
        v = json.load(f)
    assert v['cwd'] == new_path, f"cwd verify failed: {v['cwd']}"
    assert v['originCwd'] == new_path, f"originCwd verify failed: {v['originCwd']}"
    print('    ✓ Verified')

elif mode == 'cowork':
    with open(filepath) as f:
        data = json.load(f)
    folders = data.get('userSelectedFolders', [])
    updated, changes = [], 0
    for folder in folders:
        new_folder = rewrite(folder, old_base, new_base)
        if new_folder is not None:
            updated.append(new_folder)
            changes += 1
            print(f'    {folder}')
            print(f'    -> {new_folder}')
        else:
            updated.append(folder)
    if changes == 0:
        print('    - No matching paths in userSelectedFolders')
        sys.exit(0)
    data['userSelectedFolders'] = updated
    with open(filepath, 'w') as f:
        json.dump(data, f, indent=2)
    with open(filepath) as f:
        assert json.load(f)['userSelectedFolders'] == updated
    print(f'    ✓ Updated {changes} folder path(s)')

elif mode == 'codex':
    with open(filepath, 'r', encoding='utf-8', errors='surrogateescape') as f:
        lines = f.readlines()
    updated = False
    new_lines, invalid_count = [], 0
    for line in lines:
        stripped = line.strip()
        if not stripped:
            new_lines.append(line); continue
        try:
            data = json.loads(stripped)
        except json.JSONDecodeError:
            invalid_count += 1
            new_lines.append(line); continue
        if data.get('type') == 'session_meta' and 'payload' in data and 'cwd' in data['payload']:
            new_cwd = rewrite(data['payload']['cwd'], old_base, new_base)
            if new_cwd is not None:
                print(f'    {data["payload"]["cwd"]}')
                data['payload']['cwd'] = new_cwd
                new_lines.append(json.dumps(data) + '\n')
                updated = True
                print(f'    -> {new_cwd}')
            else:
                print(f'    - Skipping (cwd {data["payload"]["cwd"]} is not under {old_base})')
                new_lines.append(line)
        else:
            new_lines.append(line)
    if invalid_count > 0:
        print(f'    ⚠ {invalid_count} invalid JSONL line(s) (preserved as-is)')
    if updated:
        with open(filepath, 'w', encoding='utf-8', errors='surrogateescape') as f:
            f.writelines(new_lines)
        with open(filepath, 'r', encoding='utf-8', errors='surrogateescape') as f:
            for vline in f:
                vline = vline.strip()
                if not vline: continue
                try: vdata = json.loads(vline)
                except json.JSONDecodeError: continue
                if vdata.get('type') == 'session_meta':
                    vcwd = vdata['payload']['cwd']
                    assert vcwd == new_base or vcwd.startswith(new_base + '/'), \
                        f'Codex verify failed: {vcwd} not under {new_base}'
                    print('    ✓ Verified')
                    break
    else:
        print('    - No session_meta with matching cwd found')
PYEOF
)

run_update() {
    local mode="$1" filepath="$2"
    echo "$UPDATE_SESSION_PY" | python3 - "$mode" "$filepath" "$SESSION_PATH" "$DEST"
}

# ── Update Claude Code Desktop sessions ─────────────────
log "[4/8] Updating Claude Code Desktop sessions"

if [ ${#MATCHING_SESSIONS[@]} -eq 0 ]; then
    log "  - No sessions to update"
else
    for sf in "${MATCHING_SESSIONS[@]}"; do
        OLD_CWD=$(run_update check_cwd "$sf" 2>/dev/null || echo "")

        if [ -z "$OLD_CWD" ]; then
            log "  - Skipping (could not read cwd): $sf"
            continue
        fi

        # Verify cwd points to our project's session path, not a different project
        # that happens to share the same name as a final path component
        if [ "$OLD_CWD" != "$SESSION_PATH" ] && [[ "$OLD_CWD" != "$SESSION_PATH/"* ]]; then
            log "  - Skipping (cwd $OLD_CWD is not under $SESSION_PATH): $sf"
            continue
        fi

        log "  $OLD_CWD → $DEST"

        cp "$sf" "${sf}.bak"
        CURRENT_BACKUP="${sf}.bak"

        PYTHON_OUTPUT=$(run_update desktop "$sf") || {
            log "    ERROR: Update failed — restoring backup"
            cp "${sf}.bak" "$sf"
            CURRENT_BACKUP=""
            continue
        }
        CURRENT_BACKUP=""
        log "$PYTHON_OUTPUT"
    done
fi
log ""

# ── Copy CLI history ────────────────────────────────────
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

# ── Update Co-work session metadata ─────────────────────
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

        cp "$cf" "${cf}.bak"
        CURRENT_BACKUP="${cf}.bak"

        PYTHON_OUTPUT=$(run_update cowork "$cf") || {
            log "    ERROR: Update failed — restoring backup"
            cp "${cf}.bak" "$cf"
            CURRENT_BACKUP=""
            continue
        }
        CURRENT_BACKUP=""
        log "$PYTHON_OUTPUT"
    done
fi
log ""

# ── Update Codex session_meta cwd ───────────────────────
log "[7/8] Codex sessions"

if [ ${#CODEX_MATCHES[@]} -eq 0 ]; then
    log "  - No sessions to update"
else
    for cf in "${CODEX_MATCHES[@]}"; do
        log "  Updating: $(basename "$(dirname "$cf")")/$(basename "$cf")"

        cp "$cf" "${cf}.bak"
        CURRENT_BACKUP="${cf}.bak"

        PYTHON_OUTPUT=$(run_update codex "$cf") || {
            log "    ERROR: Update failed — restoring backup"
            cp "${cf}.bak" "$cf"
            CURRENT_BACKUP=""
            continue
        }
        CURRENT_BACKUP=""
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
