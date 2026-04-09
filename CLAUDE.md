# macos-tools

A collection of small, self-contained macOS utilities. Each utility lives in its own subdirectory with its own README and tests.

## Repository Layout

```
migrate-project/    — Migrate projects from iCloud to local, updating AI tool sessions
```

## Repository

GitHub: `rjbarbour/macos-tools`. Local working directory is `~/DocsLocal/orbstack-search/`.

## migrate-project

Safely migrate projects from `~/Documents` (iCloud-managed) to `~/DocsLocal` (local-only), updating AI tool session metadata so sessions continue to load. See `migrate-project/README.md` for full usage docs.

### Key Files

All under `migrate-project/`:

- `migrate-project.sh` — Main migration script. Usage: `bash migrate-project/migrate-project.sh <project-name>`
- `test-migrate.sh` — Test suite (15 scenarios, 51 assertions). Run: `bash migrate-project/test-migrate.sh`
- `fix-librechat-session.sh` — Original LibreChat-specific repair script (kept for reference)
- `check-size.sh`, `find-librechat.sh`, `full-diagnostic.sh`, `inspect-librechat-paths.sh` — Diagnostic scripts

### Tool Coverage

| Tool | Session Location | What's Updated |
|------|-----------------|----------------|
| Claude Code Desktop | `~/Library/Application Support/Claude/claude-code-sessions/` | `cwd` and `originCwd` in session JSON |
| Claude Code CLI | `~/.claude/projects/<encoded-path>/` | History dir copied to new encoded path |
| Claude Co-work | `~/Library/Application Support/Claude/local-agent-mode-sessions/` | `userSelectedFolders` array entries |
| Codex (OpenAI) | `~/.codex/sessions/**/*.jsonl` | `session_meta` line's `cwd` field only |
| claude.ai | Server-side | Not affected |

**Critical warning:** Desktop parent conversation history is stored in volatile Electron app state (LevelDB/memory), NOT in JSONL files. If a session goes stale before migration, the conversation history may be permanently lost.

### Claude Code Path Encoding

Given a project at `/Users/rob_dev/DocsLocal/LibreChat`, Claude Code stores CLI history at:
```
~/.claude/projects/-Users-rob-dev-DocsLocal-LibreChat
```
Rule: replace the leading `/` with `-`, then replace all remaining `/` and `_` with `-`.

### Hard-Won Lessons (Do Not Repeat)

1. **Never hardcode paths containing Migration Assistant directory names.** The apostrophe in "TMD's" is U+2019 (curly quote), not U+0027 (ASCII). Use `find -name` or shell globs instead.
2. **`pgrep -x` needs `-u "$USER"`** to avoid matching Claude processes on other logged-in macOS accounts.
3. **Never pipe rsync through `while read`/`grep` under `set -e`.** Non-matching `grep` returns exit 1, which kills the subshell, sends SIGPIPE to rsync, and terminates the copy silently.
4. **Never use `rsync --progress` for many small files.** Per-file terminal output adds ~1 second overhead per file. Use plain `rsync -a` for repos with thousands of files.
5. **rsync resumes from interrupted copies.** If the destination already exists from a previous run, rsync picks up where it left off. Don't `rm -rf` the partial copy.
6. **Copy first, verify, then update metadata.** Never modify session metadata before confirming the file copy succeeded.
7. **Each session metadata update must have its own rollback.** Back up the JSON before modifying, restore on failure, and continue to the next session rather than aborting entirely.

## Related Projects

- `~/DocsLocal/chat_session_index/` — Exports all AI session history (Claude Code, Codex) to a searchable Obsidian vault as Markdown. See its `PLAN.md` for the full session data architecture including storage paths, formats, and title chains for all tools.
