# Push to GitHub

The Cowork sandbox can't authenticate with GitHub (no access to the macOS keychain). Run these commands from Terminal or Claude Code CLI on your Mac.

## Steps

```bash
cd ~/DocsLocal/orbstack-search

# Remove stale .git from Cowork's failed sandbox attempt
rm -rf .git

# Initialize and commit
git init
git branch -M main
git add .gitignore CLAUDE.md README.md SETUP-GITHUB.md migrate-project.sh \
    test-migrate.sh fix-librechat-session.sh check-size.sh \
    find-librechat.sh full-diagnostic.sh inspect-librechat-paths.sh
git commit -m "Initial commit: macOS project migration toolkit

Safely migrates projects from ~/Documents (iCloud) to ~/DocsLocal,
updating session metadata for Claude Code Desktop, CLI, Co-work,
and Codex. Includes 45-assertion test suite.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"

# Create repo and push (requires gh CLI authenticated)
gh repo create macos-tools --public --source=. --remote=origin --push
```

## Notes

- The `.gitignore` excludes `*.txt` (machine-specific diagnostic outputs), `*.bak`, `*.log`, and `.DS_Store`
- After pushing, this file can be deleted — it's only needed for the initial setup
