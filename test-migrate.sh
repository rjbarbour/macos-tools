#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════
# test-migrate.sh — Test suite for migrate-project.sh
#
# Creates a self-contained sandbox under /tmp, simulates all four AI tool
# session stores, and exercises migrate-project.sh against them.
# ═══════════════════════════════════════════════════════════════════════
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MIGRATE="$SCRIPT_DIR/migrate-project.sh"
REAL_HOME="$HOME"

SANDBOX="/tmp/migrate-test-$$"
PASS=0
FAIL=0
ERRORS=()

# ── Colours ──────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

cleanup() {
    export HOME="$REAL_HOME"
    rm -rf "$SANDBOX"
}
trap cleanup EXIT

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
        echo -e "  ${GREEN}✓${NC} $label"
    else
        FAIL=$((FAIL + 1))
        ERRORS+=("$label: expected '$expected', got '$actual'")
        echo -e "  ${RED}✗${NC} $label"
        echo "      expected: $expected"
        echo "      actual:   $actual"
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        PASS=$((PASS + 1))
        echo -e "  ${GREEN}✓${NC} $label"
    else
        FAIL=$((FAIL + 1))
        ERRORS+=("$label: expected to contain '$needle'")
        echo -e "  ${RED}✗${NC} $label"
        echo "      expected to contain: $needle"
    fi
}

assert_file_exists() {
    local label="$1" path="$2"
    if [ -e "$path" ]; then
        PASS=$((PASS + 1))
        echo -e "  ${GREEN}✓${NC} $label"
    else
        FAIL=$((FAIL + 1))
        ERRORS+=("$label: file not found at $path")
        echo -e "  ${RED}✗${NC} $label"
    fi
}

assert_exit_code() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
        echo -e "  ${GREEN}✓${NC} $label"
    else
        FAIL=$((FAIL + 1))
        ERRORS+=("$label: expected exit $expected, got exit $actual")
        echo -e "  ${RED}✗${NC} $label"
    fi
}

# ── Sandbox setup ────────────────────────────────────────
# Sets HOME to a sandbox dir. Must NOT be called in a subshell.
setup_sandbox() {
    local test_name="$1"
    export HOME="$SANDBOX/$test_name/home"
    mkdir -p "$HOME/Documents"
    mkdir -p "$HOME/DocsLocal/orbstack-search"
    mkdir -p "$HOME/Library/Application Support/Claude/claude-code-sessions/acct1/sess1"
    mkdir -p "$HOME/Library/Application Support/Claude/local-agent-mode-sessions/inst1/user1"
    mkdir -p "$HOME/.claude/projects"
    mkdir -p "$HOME/.codex/sessions/sess1"
}

restore_home() {
    export HOME="$REAL_HOME"
}

# Create a project with some files. Prints the project dir path.
create_project() {
    local base_dir="$1"
    local project_name="$2"
    local project_dir="$base_dir/$project_name"
    mkdir -p "$project_dir/src"
    echo "module.exports = {}" > "$project_dir/src/index.js"
    echo "# README" > "$project_dir/README.md"
    echo '{"name": "test"}' > "$project_dir/package.json"
    echo "$project_dir"
}

create_desktop_session() {
    local session_dir="$1"
    local cwd="$2"
    cat > "$session_dir/local_test123.json" << ENDJSON
{
  "sessionId": "local_test123",
  "cwd": "$cwd",
  "originCwd": "$cwd",
  "title": "Test Session",
  "createdAt": "2025-01-01T00:00:00Z"
}
ENDJSON
}

create_cowork_session() {
    local session_dir="$1"
    local folder_path="$2"
    cat > "$session_dir/local_cowork456.json" << ENDJSON
{
  "sessionId": "local_cowork456",
  "cwd": "/sessions/gracious-adoring-goodall",
  "title": "Cowork Test",
  "userSelectedFolders": ["$folder_path", "/Users/testuser/Library"]
}
ENDJSON
}

create_codex_session() {
    local session_dir="$1"
    local cwd="$2"
    cat > "$session_dir/session.jsonl" << ENDJSONL
{"type":"session_meta","payload":{"cwd":"$cwd","model":"o4-mini"}}
{"type":"message","payload":{"role":"user","content":"Hello"}}
{"type":"message","payload":{"role":"assistant","content":"Hi there"}}
ENDJSONL
}

create_cli_history() {
    local cli_projects_dir="$1"
    local encoded_path="$2"
    local hist_dir="$cli_projects_dir/$encoded_path"
    mkdir -p "$hist_dir"
    echo "session history" > "$hist_dir/.history"
}

# ═══════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════"
echo "  migrate-project.sh Test Suite"
echo "═══════════════════════════════════════════════"
echo ""

# ── Test 1: No arguments → usage ─────────────────────────
echo "Test 1: No arguments shows usage"
OUTPUT=$(bash "$MIGRATE" 2>&1 || true)
assert_contains "Shows usage text" "Usage:" "$OUTPUT"

# ── Test 2: --dry-run basic project ──────────────────────
echo ""
echo "Test 2: --dry-run with basic project"
setup_sandbox "t2"
PROJECT_SRC=$(create_project "$HOME/Documents" "TestProject")
create_desktop_session "$HOME/Library/Application Support/Claude/claude-code-sessions/acct1/sess1" "$PROJECT_SRC"
create_cowork_session "$HOME/Library/Application Support/Claude/local-agent-mode-sessions/inst1/user1" "$PROJECT_SRC"
create_codex_session "$HOME/.codex/sessions/sess1" "$PROJECT_SRC"

OUTPUT=$(bash "$MIGRATE" --dry-run TestProject 2>&1)
EXIT_CODE=$?
assert_exit_code "Exits 0" "0" "$EXIT_CODE"
assert_contains "Reports source found" "Source:" "$OUTPUT"
assert_contains "Reports Desktop sessions" "Desktop" "$OUTPUT"
assert_contains "Reports Co-work sessions" "Co-work" "$OUTPUT"
assert_contains "Reports Codex sessions" "Codex" "$OUTPUT"
assert_contains "Says dry run" "DRY RUN" "$OUTPUT"
# Verify nothing was actually copied — dry-run creates the DEST dir for validation then uses it
# but should not copy files
TEST_FILES=$(find "$HOME/DocsLocal/TestProject" -type f 2>/dev/null | wc -l | tr -d ' ')
assert_eq "No files copied during dry-run" "0" "$TEST_FILES"
restore_home

# ── Test 3: Full migration with all four tools ───────────
echo ""
echo "Test 3: Full migration — copies files and updates all session metadata"
setup_sandbox "t3"
PROJECT_SRC=$(create_project "$HOME/Documents" "FullTest")
create_desktop_session "$HOME/Library/Application Support/Claude/claude-code-sessions/acct1/sess1" "$PROJECT_SRC"
create_cowork_session "$HOME/Library/Application Support/Claude/local-agent-mode-sessions/inst1/user1" "$PROJECT_SRC"
create_codex_session "$HOME/.codex/sessions/sess1" "$PROJECT_SRC"
SRC_ENCODED=$(echo "$PROJECT_SRC" | sed 's|^/|-|' | sed 's|/|-|g' | sed 's|_|-|g')
create_cli_history "$HOME/.claude/projects" "$SRC_ENCODED"

OUTPUT=$(bash "$MIGRATE" --force FullTest 2>&1)
EXIT_CODE=$?
assert_exit_code "Exits 0" "0" "$EXIT_CODE"

# Check files were copied
assert_file_exists "Project dir created" "$HOME/DocsLocal/FullTest"
assert_file_exists "Source file copied" "$HOME/DocsLocal/FullTest/src/index.js"
assert_file_exists "README copied" "$HOME/DocsLocal/FullTest/README.md"

# Check Desktop session updated
DESKTOP_CWD=$(python3 -c "
import json
with open('$HOME/Library/Application Support/Claude/claude-code-sessions/acct1/sess1/local_test123.json') as f:
    print(json.load(f)['cwd'])
")
assert_eq "Desktop cwd updated" "$HOME/DocsLocal/FullTest" "$DESKTOP_CWD"

DESKTOP_ORIGIN=$(python3 -c "
import json
with open('$HOME/Library/Application Support/Claude/claude-code-sessions/acct1/sess1/local_test123.json') as f:
    print(json.load(f)['originCwd'])
")
assert_eq "Desktop originCwd updated" "$HOME/DocsLocal/FullTest" "$DESKTOP_ORIGIN"

# Check backup created
assert_file_exists "Desktop backup created" "$HOME/Library/Application Support/Claude/claude-code-sessions/acct1/sess1/local_test123.json.bak"

# Check Co-work session updated
COWORK_FOLDER=$(python3 -c "
import json
with open('$HOME/Library/Application Support/Claude/local-agent-mode-sessions/inst1/user1/local_cowork456.json') as f:
    d = json.load(f)
    print(d['userSelectedFolders'][0])
")
assert_eq "Co-work folder updated" "$HOME/DocsLocal/FullTest" "$COWORK_FOLDER"

# Check Co-work non-matching folder preserved
COWORK_OTHER=$(python3 -c "
import json
with open('$HOME/Library/Application Support/Claude/local-agent-mode-sessions/inst1/user1/local_cowork456.json') as f:
    d = json.load(f)
    print(d['userSelectedFolders'][1])
")
assert_eq "Co-work other folder preserved" "/Users/testuser/Library" "$COWORK_OTHER"

assert_file_exists "Co-work backup created" "$HOME/Library/Application Support/Claude/local-agent-mode-sessions/inst1/user1/local_cowork456.json.bak"

# Check Codex session updated
CODEX_CWD=$(python3 -c "
import json
with open('$HOME/.codex/sessions/sess1/session.jsonl') as f:
    for line in f:
        d = json.loads(line.strip())
        if d.get('type') == 'session_meta':
            print(d['payload']['cwd'])
            break
")
assert_eq "Codex cwd updated" "$HOME/DocsLocal/FullTest" "$CODEX_CWD"

# Check Codex non-meta lines preserved
CODEX_LINE_COUNT=$(wc -l < "$HOME/.codex/sessions/sess1/session.jsonl" | tr -d ' ')
assert_eq "Codex JSONL line count preserved" "3" "$CODEX_LINE_COUNT"

assert_file_exists "Codex backup created" "$HOME/.codex/sessions/sess1/session.jsonl.bak"

# Check CLI history copied
DEST_ENCODED=$(echo "$HOME/DocsLocal/FullTest" | sed 's|^/|-|' | sed 's|/|-|g' | sed 's|_|-|g')
assert_file_exists "CLI history copied" "$HOME/.claude/projects/$DEST_ENCODED/.history"

# Check originals still exist
assert_file_exists "Source preserved" "$PROJECT_SRC/src/index.js"

restore_home

# ── Test 4: Project name with spaces ─────────────────────
echo ""
echo "Test 4: Project name with spaces"
setup_sandbox "t4"
PROJECT_SRC=$(create_project "$HOME/Documents" "Obsidian Vault")
create_desktop_session "$HOME/Library/Application Support/Claude/claude-code-sessions/acct1/sess1" "$PROJECT_SRC"

OUTPUT=$(bash "$MIGRATE" --force "Obsidian Vault" 2>&1)
EXIT_CODE=$?
assert_exit_code "Exits 0" "0" "$EXIT_CODE"
assert_file_exists "Spaced-name project copied" "$HOME/DocsLocal/Obsidian Vault/README.md"

restore_home

# ── Test 5: Project not found ────────────────────────────
echo ""
echo "Test 5: Non-existent project aborts"
setup_sandbox "t5"
OUTPUT=$(bash "$MIGRATE" --force "NoSuchProject" 2>&1 || true)
assert_contains "Reports not found" "Could not find" "$OUTPUT"
restore_home

# ── Test 6: Malformed Desktop session JSON ───────────────
echo ""
echo "Test 6: Malformed session JSON — skips and continues"
setup_sandbox "t6"
PROJECT_SRC=$(create_project "$HOME/Documents" "BadJSON")

# Create a valid session
create_desktop_session "$HOME/Library/Application Support/Claude/claude-code-sessions/acct1/sess1" "$PROJECT_SRC"

# Create a second session dir with malformed JSON that still matches grep
mkdir -p "$HOME/Library/Application Support/Claude/claude-code-sessions/acct1/sess2"
echo "{bad json /BadJSON\"" > "$HOME/Library/Application Support/Claude/claude-code-sessions/acct1/sess2/local_broken.json"

OUTPUT=$(bash "$MIGRATE" --force BadJSON 2>&1)
EXIT_CODE=$?
assert_exit_code "Completes despite bad JSON" "0" "$EXIT_CODE"

# The valid session should still be updated
DESKTOP_CWD=$(python3 -c "
import json
with open('$HOME/Library/Application Support/Claude/claude-code-sessions/acct1/sess1/local_test123.json') as f:
    print(json.load(f)['cwd'])
")
assert_eq "Valid session still updated" "$HOME/DocsLocal/BadJSON" "$DESKTOP_CWD"

restore_home

# ── Test 7: Resumable copy (destination already exists) ──
echo ""
echo "Test 7: Resumable copy — destination already partially exists"
setup_sandbox "t7"
PROJECT_SRC=$(create_project "$HOME/Documents" "ResumeTest")
# Pre-create partial destination
mkdir -p "$HOME/DocsLocal/ResumeTest/src"
echo "old content" > "$HOME/DocsLocal/ResumeTest/src/index.js"

OUTPUT=$(bash "$MIGRATE" --force ResumeTest 2>&1)
EXIT_CODE=$?
assert_exit_code "Exits 0 with existing dest" "0" "$EXIT_CODE"
assert_contains "Reports resume" "resume" "$OUTPUT"

# Content should be updated by rsync
CONTENT=$(cat "$HOME/DocsLocal/ResumeTest/src/index.js")
assert_eq "Content updated by rsync" "module.exports = {}" "$CONTENT"

restore_home

# ── Test 8: No session references (copy-only) ───────────
echo ""
echo "Test 8: Project with no session references — copy only"
setup_sandbox "t8"
PROJECT_SRC=$(create_project "$HOME/Documents" "NoSessions")

OUTPUT=$(bash "$MIGRATE" --force NoSessions 2>&1)
EXIT_CODE=$?
assert_exit_code "Exits 0" "0" "$EXIT_CODE"
assert_file_exists "Files still copied" "$HOME/DocsLocal/NoSessions/README.md"
assert_contains "Warns no references" "No Claude Code" "$OUTPUT"

restore_home

# ── Test 9: Desktop session cwd points elsewhere ────────
echo ""
echo "Test 9: grep match but cwd points elsewhere — still runs"
setup_sandbox "t9"
PROJECT_SRC=$(create_project "$HOME/Documents" "Overlap")

# Session mentions "Overlap" in cwd but different path structure
cat > "$HOME/Library/Application Support/Claude/claude-code-sessions/acct1/sess1/local_test123.json" << ENDJSON
{
  "sessionId": "local_test123",
  "cwd": "/some/other/Overlap/path",
  "originCwd": "/some/other/Overlap/path",
  "title": "Overlap Test"
}
ENDJSON

OUTPUT=$(bash "$MIGRATE" --force Overlap 2>&1)
EXIT_CODE=$?
assert_exit_code "Exits 0" "0" "$EXIT_CODE"
assert_file_exists "Files copied" "$HOME/DocsLocal/Overlap/README.md"

restore_home

# ── Test 10: Codex JSONL with no session_meta line ───────
echo ""
echo "Test 10: Codex JSONL without session_meta — no crash"
setup_sandbox "t10"
PROJECT_SRC=$(create_project "$HOME/Documents" "CodexNoMeta")

# JSONL file mentions project name in cwd-like field, but type is not session_meta
# The grep pattern is -Frl "/CodexNoMeta\"" so the file must contain /CodexNoMeta"
# We put it in a non-session_meta line's cwd-like field
python3 -c "
import json
line = json.dumps({'type': 'environment', 'payload': {'cwd': '$HOME/Documents/CodexNoMeta'}})
print(line)
line2 = json.dumps({'type': 'message', 'payload': {'role': 'user', 'content': 'Hello'}})
print(line2)
" > "$HOME/.codex/sessions/sess1/session.jsonl"

OUTPUT=$(bash "$MIGRATE" --force CodexNoMeta 2>&1)
EXIT_CODE=$?
assert_exit_code "Exits 0" "0" "$EXIT_CODE"
assert_contains "No session_meta" "No session_meta" "$OUTPUT"

restore_home

# ── Test 11: Normal project name resolves within DocsLocal
echo ""
echo "Test 11: Path traversal check passes for normal names"
setup_sandbox "t11"
mkdir -p "$HOME/Documents/legit"
echo "test" > "$HOME/Documents/legit/file.txt"

OUTPUT=$(bash "$MIGRATE" --force "legit" 2>&1)
EXIT_CODE=$?
assert_exit_code "Normal name exits 0" "0" "$EXIT_CODE"

restore_home

# ── Test 12: Ambiguous project name (multiple matches) ───
echo ""
echo "Test 12: Ambiguous project name — multiple directories"
setup_sandbox "t12"
mkdir -p "$HOME/Documents/myproject/src"
echo "a" > "$HOME/Documents/myproject/src/a.txt"
mkdir -p "$HOME/Documents/subfolder/myproject/src"
echo "b" > "$HOME/Documents/subfolder/myproject/src/b.txt"

OUTPUT=$(bash "$MIGRATE" --force "myproject" 2>&1 || true)
assert_contains "Reports ambiguous" "Ambiguous" "$OUTPUT"

restore_home

# ── Test 13: Codex backup preserves original ─────────────
echo ""
echo "Test 13: Codex backup file contains original content"
setup_sandbox "t13"
PROJECT_SRC=$(create_project "$HOME/Documents" "CodexBackup")
create_codex_session "$HOME/.codex/sessions/sess1" "$PROJECT_SRC"

# Save original for comparison
ORIGINAL=$(cat "$HOME/.codex/sessions/sess1/session.jsonl")

OUTPUT=$(bash "$MIGRATE" --force CodexBackup 2>&1)

BACKUP=$(cat "$HOME/.codex/sessions/sess1/session.jsonl.bak")
assert_eq "Codex backup matches original" "$ORIGINAL" "$BACKUP"

restore_home

# ── Test 14: Co-work subpath matching ────────────────────
echo ""
echo "Test 14: Co-work subpath replacement (project/subdir)"
setup_sandbox "t14"
PROJECT_SRC=$(create_project "$HOME/Documents" "SubPath")

# Co-work session has a mount pointing to a subdir of the project
cat > "$HOME/Library/Application Support/Claude/local-agent-mode-sessions/inst1/user1/local_cowork456.json" << ENDJSON
{
  "sessionId": "local_cowork456",
  "cwd": "/sessions/test-session",
  "title": "SubPath Test",
  "userSelectedFolders": ["$PROJECT_SRC/deep/nested/dir", "$PROJECT_SRC", "/other/path"]
}
ENDJSON

OUTPUT=$(bash "$MIGRATE" --force SubPath 2>&1)
EXIT_CODE=$?
assert_exit_code "Exits 0" "0" "$EXIT_CODE"

COWORK_FOLDERS=$(python3 -c "
import json
with open('$HOME/Library/Application Support/Claude/local-agent-mode-sessions/inst1/user1/local_cowork456.json') as f:
    d = json.load(f)
    for folder in d['userSelectedFolders']:
        print(folder)
")
FOLDER1=$(echo "$COWORK_FOLDERS" | sed -n '1p')
FOLDER2=$(echo "$COWORK_FOLDERS" | sed -n '2p')
FOLDER3=$(echo "$COWORK_FOLDERS" | sed -n '3p')
assert_eq "Subpath rewritten" "$HOME/DocsLocal/SubPath/deep/nested/dir" "$FOLDER1"
assert_eq "Exact path rewritten" "$HOME/DocsLocal/SubPath" "$FOLDER2"
assert_eq "Unrelated path preserved" "/other/path" "$FOLDER3"

restore_home

# ═══════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════"
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
    echo -e "  ${GREEN}ALL $TOTAL TESTS PASSED${NC}"
else
    echo -e "  ${RED}$FAIL FAILED${NC} / $TOTAL total"
    echo ""
    for err in "${ERRORS[@]}"; do
        echo -e "  ${RED}✗${NC} $err"
    done
fi
echo "═══════════════════════════════════════════════"
echo ""

exit "$FAIL"
