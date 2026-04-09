#!/bin/bash
# Inspect all paths relevant to the missing LibreChat directory
OUT=~/DocsLocal/orbstack-search/path-inspection.txt

echo "=== INSPECTION: $(date) ===" > "$OUT"

echo -e "\n--- 1. What is ~/Documents? (symlink? iCloud?) ---" >> "$OUT"
ls -la ~/Documents >> "$OUT" 2>&1

echo -e "\n--- 2. Does ~/Documents/GitHub exist? ---" >> "$OUT"
ls -la ~/Documents/GitHub/ >> "$OUT" 2>&1

echo -e "\n--- 3. Does the original LibreChat path exist? ---" >> "$OUT"
ls -la ~/Documents/GitHub/LibreChat >> "$OUT" 2>&1

echo -e "\n--- 4. iCloud Documents - is LibreChat there? ---" >> "$OUT"
find ~/Library/Mobile\ Documents/com~apple~CloudDocs -maxdepth 5 -name "LibreChat" 2>/dev/null >> "$OUT"
echo "(empty = not found in iCloud)" >> "$OUT"

echo -e "\n--- 5. Broader search for any LibreChat directory on disk ---" >> "$OUT"
find ~ -maxdepth 5 -name "LibreChat" -type d 2>/dev/null >> "$OUT"
echo "(empty = not found anywhere)" >> "$OUT"

echo -e "\n--- 6. Claude Code CLI project history for LibreChat ---" >> "$OUT"
ls -la ~/.claude/projects/ | grep -i libre >> "$OUT" 2>&1
echo "" >> "$OUT"
ls ~/.claude/projects/-Users-rob*-Documents-GitHub-LibreChat/ >> "$OUT" 2>&1

echo -e "\n--- 7. Desktop app session metadata ---" >> "$OUT"
cat ~/Library/Application\ Support/Claude/claude-code-sessions/*/1eed8875-1eba-4cea-be7f-0a052a362125/local_4e427008-833e-4e08-a2d7-2e55ec995f61.json 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps({k:v for k,v in d.items() if k in ['cwd','originCwd','sessionId','title','isArchived']}, indent=2))" >> "$OUT" 2>&1

echo -e "\n--- 8. macOS iCloud sync status for Documents ---" >> "$OUT"
brctl status ~/Documents 2>/dev/null >> "$OUT" || echo "brctl not available or Documents not iCloud-managed" >> "$OUT"

echo -e "\n--- 9. Is Documents a symlink or real directory? ---" >> "$OUT"
file ~/Documents >> "$OUT" 2>&1
stat ~/Documents >> "$OUT" 2>&1

echo -e "\nDone. Output at: $OUT"
