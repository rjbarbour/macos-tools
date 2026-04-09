# migrate-project

Migrate projects out of iCloud-managed `~/Documents` into a local directory, preserving AI tool session references across Claude Code (Desktop, CLI, Co-work) and OpenAI Codex.

## Why

macOS Migration Assistant creates nested directories under `~/Documents` (e.g. `Documents - <OldMacName>/`). With iCloud Drive syncing `~/Documents`, node_modules, Docker data, and git repos are synced unnecessarily. Worse, AI coding tools store absolute paths in session metadata — when files move, sessions break with "Folder no longer exists."

## Quick Start

```bash
# Quit Claude Desktop first (Cmd+Q), then:
bash migrate-project.sh <project-name>

# Options:
#   --dry-run   Show what would happen without making any changes
#   --force     Skip the interactive confirmation prompt

# Examples:
bash migrate-project.sh MyProject
bash migrate-project.sh "Obsidian Vault"
bash migrate-project.sh --dry-run Projects
```

## What It Does

1. **Finds** the project under `~/Documents` (handles Unicode directory names automatically)
2. **Copies** to `~/DocsLocal/<project-name>` using rsync (resumable if interrupted)
3. **Verifies** the copy by comparing file counts
4. **Updates** Claude Code Desktop session metadata (`cwd` and `originCwd` in session JSON)
5. **Updates** Claude Co-work session metadata (`userSelectedFolders` mount paths)
6. **Updates** Codex session_meta `cwd` in JSONL (conversation content untouched)
7. **Copies** Claude Code CLI project history to the new encoded path

Nothing is deleted. Originals are preserved. Session JSON files are backed up to `.bak` before modification.

## AI Tool Compatibility

| Tool | Affected by move? | Handled by script? | Notes |
|------|---|---|---|
| Claude Code Desktop | Yes — `cwd`/`originCwd` in session JSON | Yes | Must quit Desktop before running |
| Claude Code CLI | Yes — project history at `~/.claude/projects/<encoded-path>/` | Yes | History copied to new path |
| Claude Co-work | Yes — `userSelectedFolders` in session JSON | Yes | Mount paths updated to new location |
| Codex (OpenAI) | Yes — `cwd` in session_meta JSONL | Yes | Only session_meta line rewritten; content untouched |
| claude.ai | No | N/A | Server-side only |

**Important:** Claude Code Desktop stores the parent conversation in volatile app memory, not on disk. If a session breaks ("Folder no longer exists") before you migrate, the conversation history may be permanently lost. Subagent work (JSONL files, git commits) is preserved, but the planning/delegation dialogue is not recoverable. Migrate early.

## After Running

1. Relaunch Claude Desktop
2. Verify your sessions load
3. Optionally delete originals (the script prints the exact `rm -rf` command)

## Testing

The test suite creates isolated sandboxes, simulates all four AI tool session stores, and validates the full migration pipeline:

```bash
bash test-migrate.sh
```

15 test scenarios, 51 assertions. Covers spaces in names, Unicode paths, malformed JSON, resumable copies, ambiguous matches, path traversal, subpath replacement, and more. No side effects on the real system.

## Files

| File | Purpose |
|------|---------|
| `migrate-project.sh` | Generic migration script |
| `test-migrate.sh` | Test suite (15 scenarios, 51 assertions) |
| `fix-librechat-session.sh` | Original LibreChat-specific script (reference) |
| `CLAUDE.md` | Technical context for AI coding tools |
| Diagnostic scripts | `check-size.sh`, `find-librechat.sh`, `full-diagnostic.sh`, `inspect-librechat-paths.sh` |

## Requirements

- macOS with Python 3 (pre-installed)
- `rsync` (pre-installed)
- `~/DocsLocal` must exist
- Claude Desktop must be quit before running

## License

MIT
