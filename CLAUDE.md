# macos-tools — Project Migration Toolkit

## Purpose

Safely migrate projects from `~/Documents` (iCloud-managed) to `~/DocsLocal` (local-only), updating AI tool session metadata so sessions continue to load.

## Background

macOS Migration Assistant imports from a previous Mac create a nested subdirectory under `~/Documents` called `Documents - <OldMacName>` (note: the apostrophe in the name is Unicode U+2019 curly quote, not ASCII). When `~/Documents` syncs to iCloud Drive, projects with node_modules, Docker data, and git repos waste sync bandwidth and break tools that store absolute paths.

Multiple AI tools store session metadata that includes the project's absolute working directory path. When the directory moves, sessions break. This toolkit copies the project to a safe location and updates all metadata references.

## Tool Coverage

### Claude Code Desktop — Fully Supported

Session metadata stored at `~/Library/Application Support/Claude/claude-code-sessions/<account-id>/<session-id>/local_<uuid>.json`. Contains `cwd` and `originCwd` fields pointing to the project directory. The script finds all session files referencing the project name and updates both fields.

**Critical warning:** Desktop parent conversation history is stored in volatile Electron app state (LevelDB/memory), NOT in JSONL files. If a session goes stale (e.g. "Folder no longer exists"), the conversation history may be permanently lost. Migrate projects *before* this happens. Subagent JSONL is preserved but the parent user-Claude dialogue is not recoverable.

### Claude Code CLI — Fully Supported

Project history stored at `~/.claude/projects/<encoded-path>/` where paths are encoded by replacing `/` with `-` and `_` with `-`. The script copies CLI history to the new encoded path.

### Claude Co-work (Desktop) — Fully Supported

Co-work runs inside a sandboxed Linux VM with its own filesystem. The `cwd` in session JSON is a whimsical sandbox path (`/sessions/<adjective-adjective-scientist>`) that doesn't reference real directories. However, each session stores `userSelectedFolders` — an array of absolute host paths that the user selected as mounts. If a project directory moves, Cowork won't know where to find the files when resuming that session.

Session metadata is stored at `~/Library/Application Support/Claude/local-agent-mode-sessions/<install-id>/<user-id>/local_<uuid>.json`. The script finds sessions with matching `userSelectedFolders` entries and rewrites them to the new location.

Note: a single Cowork session may mount multiple folders (e.g. `~/Library`, `~/Documents`, `~/DocsLocal`). The script only rewrites entries matching the migrated project, leaving other mounts untouched.

### Codex (OpenAI) — Fully Supported

Codex sessions are stored at `~/.codex/sessions/**/*.jsonl` with an index at `~/.codex/session_index.jsonl`. Each Codex JSONL file contains a `session_meta` record with a `cwd` field — the working directory the session ran in. If you resume a Codex session after moving the project, it opens but tries to work in a directory that no longer exists.

The migration script finds Codex JSONL files referencing the project, backs them up, and rewrites only the `session_meta` line's `cwd` field to the new path. All other JSONL lines (conversation content, tool calls, environment context) are passed through unchanged. Note: the modified `session_meta` line is re-serialised via `json.dumps()`, so field ordering and whitespace of that one line may differ from the original — the data is preserved but the formatting is not. The `.bak` file retains the original bytes.

The SQLite file (`~/.codex/logs_1.sqlite`) is an application debug log, not a conversation store — it adds nothing beyond what JSONL provides.

### claude.ai — Not Applicable

Conversation history is server-side only. Not affected by local directory moves.

## Key Files

- `migrate-project.sh` — Generic migration script. Usage: `bash migrate-project.sh <project-name>`
- `test-migrate.sh` — Test suite (14 scenarios, 45 assertions). Run: `bash test-migrate.sh`
- `fix-librechat-session.sh` — Original LibreChat-specific repair script (kept for reference)
- `check-size.sh`, `find-librechat.sh`, `full-diagnostic.sh`, `inspect-librechat-paths.sh` — Diagnostic scripts from the original LibreChat investigation
- `.gitignore` — Excludes machine-specific outputs (`*.txt` logs, `*.bak` backups, `migrate-*.log`)

## Repository

GitHub: `rjbarbour/macos-tools` (or wherever pushed). Local working directory is `~/DocsLocal/orbstack-search/`.

To create the repo and push:
```bash
cd ~/DocsLocal/orbstack-search
gh repo create macos-tools --public --source=. --remote=origin --push
```

## Test Suite

`test-migrate.sh` creates isolated sandboxes under `/tmp`, simulates all four AI tool session stores, and validates the full migration pipeline. 14 test scenarios covering:

- Dry-run mode (no side effects)
- Full end-to-end migration with all four tools (Desktop, CLI, Co-work, Codex)
- Project names with spaces ("Obsidian Vault")
- Non-existent project (clean abort)
- Malformed session JSON (skip bad, update good)
- Resumable copy (destination partially exists)
- Copy-only with no session references
- grep match but cwd points elsewhere
- Codex JSONL without session_meta line
- Path traversal validation
- Ambiguous project name (multiple matches)
- Backup file integrity
- Co-work subpath replacement (mounts to subdirectories)

Run: `bash test-migrate.sh` — creates and cleans up its own sandbox, no side effects on the real system.

## Related Projects

- `~/DocsLocal/chat_session_index/` — Exports all AI session history (Claude Code, Codex) to a searchable Obsidian vault as Markdown. See its `PLAN.md` for the full session data architecture including storage paths, formats, and title chains for all tools.

## Hard-Won Lessons (Do Not Repeat)

1. **Never hardcode paths containing Migration Assistant directory names.** The apostrophe in "TMD's" is U+2019 (curly quote), not U+0027 (ASCII). Use `find -name` or shell globs instead.
2. **`pgrep -x` needs `-u "$USER"`** to avoid matching Claude processes on other logged-in macOS accounts.
3. **Never pipe rsync through `while read`/`grep` under `set -e`.** Non-matching `grep` returns exit 1, which kills the subshell, sends SIGPIPE to rsync, and terminates the copy silently.
4. **Never use `rsync --progress` for many small files.** Per-file terminal output adds ~1 second overhead per file. Use plain `rsync -a` for repos with thousands of files.
5. **rsync resumes from interrupted copies.** If the destination already exists from a previous run, rsync picks up where it left off. Don't `rm -rf` the partial copy.
6. **Copy first, verify, then update metadata.** Never modify session metadata before confirming the file copy succeeded. The script verifies file counts match before touching any JSON.
7. **Each session metadata update must have its own rollback.** Back up the JSON before modifying, restore on failure, and continue to the next session rather than aborting entirely.

## Claude Code Path Encoding

Given a project at `/Users/rob_dev/DocsLocal/LibreChat`, Claude Code stores CLI history at:
```
~/.claude/projects/-Users-rob-dev-DocsLocal-LibreChat
```
Rule: replace the leading `/` with `-`, then replace all remaining `/` and `_` with `-`. The result always starts with `-`.

## Session Metadata Structure

Files at `~/Library/Application Support/Claude/claude-code-sessions/<account-id>/<session-id>/local_<uuid>.json` contain:
```json
{
  "sessionId": "local_<uuid>",
  "cwd": "/Users/rob_dev/DocsLocal/LibreChat",
  "originCwd": "/Users/rob_dev/DocsLocal/LibreChat",
  ...
}
```
Both `cwd` and `originCwd` must be updated together.

## Projects Available for Migration

From `~/Documents/Documents - TMD's MacBook Pro/`:
- `GitHub/` — contains sub-projects (LibreChat already migrated)
- `huggingface/`
- `Obsidian Vault/`
- `Projects/`
- `Reference/`
- `Zoom/`
