#!/bin/bash
OUT="$HOME/DocsLocal/orbstack-search/librechat-location.txt"
echo "=== LibreChat Location Search: $(date) ===" > "$OUT"
echo "" >> "$OUT"

echo "--- Checking expected path ---" >> "$OUT"
ls -la "$HOME/Documents/Documents - TMD's MacBook Pro/GitHub/LibreChat" >> "$OUT" 2>&1

echo "" >> "$OUT"
echo "--- Searching all of ~/Documents for LibreChat ---" >> "$OUT"
find "$HOME/Documents" -maxdepth 5 -type d -name "LibreChat" >> "$OUT" 2>&1

echo "" >> "$OUT"
echo "--- Searching ~/DocsLocal for LibreChat ---" >> "$OUT"
find "$HOME/DocsLocal" -maxdepth 3 -type d -name "LibreChat" >> "$OUT" 2>&1

echo "" >> "$OUT"
echo "--- Listing ~/Documents top level ---" >> "$OUT"
ls -la "$HOME/Documents/" >> "$OUT" 2>&1

echo "" >> "$OUT"
echo "Done. Results at: $OUT"
cat "$OUT"
