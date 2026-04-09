#!/bin/bash
OUT="$HOME/DocsLocal/orbstack-search/size-check.txt"
SRC=$(find "$HOME/Documents" -maxdepth 5 -type d -name "LibreChat" 2>/dev/null | head -1)

echo "=== Size Check: $(date) ===" > "$OUT"

echo "" >> "$OUT"
echo "--- Total source size ---" >> "$OUT"
du -sh "$SRC" >> "$OUT" 2>&1

echo "" >> "$OUT"
echo "--- Top-level directories by size (sorted) ---" >> "$OUT"
du -sh "$SRC"/*/ 2>/dev/null | sort -rh | head -20 >> "$OUT"

echo "" >> "$OUT"
echo "--- Total file count ---" >> "$OUT"
find "$SRC" -type f 2>/dev/null | wc -l >> "$OUT"

echo "" >> "$OUT"
echo "--- Partial copy at destination ---" >> "$OUT"
if [ -d "$HOME/DocsLocal/LibreChat" ]; then
    du -sh "$HOME/DocsLocal/LibreChat" >> "$OUT" 2>&1
    echo "File count:" >> "$OUT"
    find "$HOME/DocsLocal/LibreChat" -type f 2>/dev/null | wc -l >> "$OUT"
else
    echo "No partial copy found (already clean)" >> "$OUT"
fi

echo "" >> "$OUT"
echo "--- Disk free ---" >> "$OUT"
df -h "$HOME/DocsLocal" >> "$OUT" 2>&1

echo "" >> "$OUT"
echo "=== Done ===" >> "$OUT"
cat "$OUT"
