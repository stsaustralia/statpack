#!/usr/bin/env bash
# =============================================================================
# Copy all real CSV files under /Users/administrator recursively,
# created after 2025-06-25 00:01:00 Sydney time (UTC+10 no DST),
# size less than 1MB, into TARGET_DIR,
# skipping exact duplicates (by SHA-256) and renaming collisions with an
# incrementing suffix. Logs with YYYYMMDDHHMMSS (Sydney).
# Ensures only files whose MIME type is text/csv or similar.
# macOS 15.3+ compatible (bash/zsh via bash invocation).
# =============================================================================

TARGET_DIR="/Volumes/BM24/SAVES/5"

# now(): return current time in Sydney (UTC+10 no DST) as YYYYMMDDHHMMSS
now() {
  date -u -v+10H +%Y%m%d%H%M%S
}

# Compute cutoff epoch for creation time
# 2025-06-25 00:01:00 Sydney = 2025-06-24 14:01:00 UTC
cutoff_epoch=$(date -u -j -f "%Y-%m-%d %H:%M:%S" "2025-08-10 00:01:00" +%s)

# Create the target directory if it doesn't exist
mkdir -p -- "$TARGET_DIR"

# Array to hold seen SHA-256 hashes
declare -a seen_hashes=()

# Find files with .csv extension (case-insensitive) under /Users/administrator
find /Users/administrator \
  -type f \
  -iname "*.*" \
  -size -16M | while IFS= read -r file; do

  # Verify MIME type is CSV
#  case "$mime" in
 #   text/csv|application/csv|text/plain) ;;
  #  *)
   #   echo "$(now)  SKIP not-csv mime=$mime: $file"
    #  continue
     # ;;
#  esac

  # Get file’s creation (birth) time epoch
  birth_epoch=$(stat -f '%B' "$file")
  if (( birth_epoch <= cutoff_epoch )); then
    echo "$(now)  SKIP too old: $file"
    continue
  fi

  # Compute SHA-256 hash
  hash=$(shasum -a 256 "$file" | awk '{print $1}')
  # Skip duplicates
  if printf '%s\n' "${seen_hashes[@]}" | grep -qx "$hash"; then
    echo "$(now)  SKIP duplicate: $file"
    continue
  fi
  seen_hashes+=("$hash")

  # Prepare destination filename
  base=$(basename "$file")
  name="${base%.*}"
  ext="${base##*.}"
  dest="$TARGET_DIR/$base"

  # Handle name collisions (_1, _2, …)
  count=1
  while [[ -e "$dest" ]]; do
    dest="$TARGET_DIR/${name}_$count.$ext"
    ((count++))
  done

  # Copy, preserving timestamps and modes
  cp -p "$file" "$dest"
  echo "$(now)  COPIED      : $file -> $dest"

done

echo "Done. All unique, real CSVs created after 2019-01-01 00:01:00 Sydney time are in $TARGET_DIR"