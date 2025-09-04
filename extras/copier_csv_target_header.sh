#!/usr/bin/env bash
# =============================================================================
# Copy all unique CSV files under /Users/administrator that:
#   - were created after a cutoff time
#   - have a header row exactly matching TARGET_HEADER
# Skips duplicates (by SHA-256), renames on collision, logs in Sydney time.
# =============================================================================

TARGET_HEADER="Timestamp,Since Dose,Elapsed,Info,Scale,Drug,Qty,ROA,Rush Sum,Rush Label,Mood Sum,Mood Label,Social Sum,Social Label,Energy Sum,Energy Label,Focus Sum,Focus Label,Anxiety Sum,Anxiety Label,Impair Sum,Impair Label,Change Sum,Change Label,Degree Sum,Degree Label,Other Sum,Other Label,Score,Max,Min,Max %,Min %,Valence,scaleMood,scaleBad,scaleFocus,Custom Notes,Notes,Weighted,Score5,Good Sum,Input Source"   # <== YOUR TARGET HEADER
TARGET_DIR="/Users/Shared/cx/cx1"
CUTOFF_DATE="2007-01-01 23:59:00"            # "" to disable time filtering

# Sydney timestamp
now() {
  date -u -v+10H +%Y%m%d%H%M%S
}

# Convert cutoff to epoch
if [[ -n "$CUTOFF_DATE" ]]; then
  cutoff_epoch=$(date -u -j -f "%Y-%m-%d %H:%M:%S" "$CUTOFF_DATE" +%s)
else
  cutoff_epoch=0
fi

mkdir -p -- "$TARGET_DIR"
declare -a seen_hashes=()

find /Users/administrator/NEWLOGS -type f -iname "*.csv" -size -1M | while IFS= read -r file; do
  # Check MIME type is text or CSV
 # mime=$(file --mime-type -b "$file")
 # case "$mime" in
  #  text/csv|application/csv|text/plain|image/png) ;;
  #  *) echo "$(now)  SKIP not CSV mime=$mime: $file"; continue ;;
#  esac

  # Check creation time
  birth_epoch=$(stat -f '%B' "$file")
  if (( birth_epoch <= cutoff_epoch )); then
    echo "$(now)  SKIP too old: $file"
    continue
  fi

  # Read first non-empty line
  header=$(awk 'NF { print; exit }' "$file")
  if [[ "$header" != "$TARGET_HEADER" ]]; then
    echo "$(now)  SKIP header mismatch: $file"
    continue
  fi

  # Check hash to skip duplicates
  hash=$(shasum -a 256 "$file" | awk '{print $1}')
  if printf '%s\n' "${seen_hashes[@]}" | grep -qx "$hash"; then
    echo "$(now)  SKIP duplicate: $file"
    continue
  fi
  seen_hashes+=("$hash")

  # Prepare destination name with suffix if needed
  base=$(basename "$file")
  name="${base%.*}"
  ext="${base##*.}"
  dest="$TARGET_DIR/$base"
  count=1
  while [[ -e "$dest" ]]; do
    dest="$TARGET_DIR/${name}_$count.$ext"
    ((count++))
  done

  cp -p "$file" "$dest"
  echo "$(now)  COPIED      : $file -> $dest"
done

echo "$(now)  ✅ Done. All CSVs with matching header copied to $TARGET_DIR"
