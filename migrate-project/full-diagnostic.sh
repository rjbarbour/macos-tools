#!/bin/bash
OUT="$HOME/DocsLocal/orbstack-search/full-diagnostic.txt"
echo "=== Full Diagnostic: $(date) ===" > "$OUT"

echo "" >> "$OUT"
echo "--- 1. Find LibreChat anywhere under ~/Documents (simple, no path filter) ---" >> "$OUT"
find "$HOME/Documents" -maxdepth 5 -type d -name "LibreChat" >> "$OUT" 2>&1

echo "" >> "$OUT"
echo "--- 2. Find LibreChat with the -path filter the repair script uses ---" >> "$OUT"
find "$HOME/Documents" -maxdepth 4 -type d -name "LibreChat" -path "*/TMD*MacBook Pro/GitHub/*" >> "$OUT" 2>&1

echo "" >> "$OUT"
echo "--- 3. Hex dump of the 'Documents - TMD' directory name (to check for special chars) ---" >> "$OUT"
ls -1 "$HOME/Documents/" | grep "TMD" | xxd >> "$OUT" 2>&1

echo "" >> "$OUT"
echo "--- 4. Does ~/Documents/GitHub/LibreChat exist? ---" >> "$OUT"
ls -la "$HOME/Documents/GitHub/" >> "$OUT" 2>&1

echo "" >> "$OUT"
echo "--- 5. What's inside Documents - TMD*? ---" >> "$OUT"
# Use glob to avoid apostrophe issues
for d in "$HOME/Documents/Documents - TMD"*; do
    echo "Found dir: $d" >> "$OUT"
    ls -la "$d/" >> "$OUT" 2>&1
done

echo "" >> "$OUT"
echo "--- 6. Session metadata file exists? ---" >> "$OUT"
SESSION_FILE="$HOME/Library/Application Support/Claude/claude-code-sessions/1540220d-0573-4ef1-b8c9-8154e4e250ea/1eed8875-1eba-4cea-be7f-0a052a362125/local_4e427008-833e-4e08-a2d7-2e55ec995f61.json"
if [ -f "$SESSION_FILE" ]; then
    echo "YES - exists" >> "$OUT"
    echo "First 200 chars:" >> "$OUT"
    head -c 200 "$SESSION_FILE" >> "$OUT"
    echo "" >> "$OUT"
    # Extract cwd and originCwd
    python3 -c "
import json
with open('$SESSION_FILE') as f:
    d = json.load(f)
print('cwd:', d.get('cwd','NOT SET'))
print('originCwd:', d.get('originCwd','NOT SET'))
" >> "$OUT" 2>&1
else
    echo "NO - not found" >> "$OUT"
fi

echo "" >> "$OUT"
echo "--- 7. CLI project history directories matching *LibreChat* ---" >> "$OUT"
find "$HOME/.claude/projects/" -maxdepth 1 -type d -name "*LibreChat*" >> "$OUT" 2>&1

echo "" >> "$OUT"
echo "--- 8. Does ~/DocsLocal/LibreChat already exist? ---" >> "$OUT"
if [ -d "$HOME/DocsLocal/LibreChat" ]; then
    echo "YES - already exists (repair script will abort)" >> "$OUT"
    ls -la "$HOME/DocsLocal/LibreChat/" >> "$OUT" 2>&1
else
    echo "NO - clear for copy" >> "$OUT"
fi

echo "" >> "$OUT"
echo "--- 9. Is Claude Desktop running (current user only)? ---" >> "$OUT"
if pgrep -x -u "$USER" "Claude" > /dev/null 2>&1; then
    echo "YES - running" >> "$OUT"
else
    echo "NO - not running" >> "$OUT"
fi

echo "" >> "$OUT"
echo "--- 10. Disk space ---" >> "$OUT"
df -h "$HOME/DocsLocal" >> "$OUT" 2>&1

echo "" >> "$OUT"
echo "=== Diagnostic complete ===" >> "$OUT"
cat "$OUT"
