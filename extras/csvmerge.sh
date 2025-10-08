#!/bin/bash
# merge.sh
# Usage: ./merge.sh /path/to/source

SRC_DIR="$1"
OUTFILE="mergedcsvfiles2.csv"

if [ -z "$SRC_DIR" ]; then
    echo "Usage: $0 /path/to/source"
    exit 1
fi

> "$OUTFILE"
first=true

find "$SRC_DIR" -maxdepth 1 -type f -name "*.csv" -print0 | sort -z | while IFS= read -r -d '' f; do
    if $first; then
        cat "$f" >> "$OUTFILE"
        first=false
    else
        tail -n +2 "$f" >> "$OUTFILE"
    fi
done

echo "Merged CSV saved as $OUTFILE"
