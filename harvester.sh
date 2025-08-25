#!/usr/bin/env bash
# =============================================================================
# Combined CSV Harvester with Toggles (macOS 15.3+)
#
# - Recursively scan SOURCE_DIR for candidate files
# - Apply optional filters (size/date/extension/filename/regex/MIME/header modes)
# - Skip duplicates by SHA-256 (within-run and/or vs existing target)
# - Copy to TARGET_DIR with collision-safe renaming, or run in DRY-RUN mode
#
# Time zone policy: Sydney, Australia (UTC+10, no DST). All log timestamps are
# Sydney time formatted as YYYYMMDDHHMMSS.
#
# Notes:
# - Creation time read via: stat -f '%B' (BSD/macOS)
# - MIME type via: file --mime-type -b
# - Header = first non-empty line
# - "first word" means the first token of the header up to a comma or whitespace
# - "at least X headers" checks header column count (comma-separated) >= X
#
# Dependencies: bash, stat, awk, sed, shasum, file, find, mkdir, cp
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# --------------------------- CONFIGURATION -----------------------------------

# Where to look and where to store copies
SOURCE_DIR="/Users/administrator"
TARGET_DIR="/Users/Shared/out/1/1"

# Logging
LOG_TO_FILE=false
LOG_FILE="/Users/Shared/SaveCombo/log250826x.log"

# Copy toggle (true = actually copy; false = DRY RUN, log only)
COPY_ENABLED=true

# Duplicate detection
HASH_DEDUP_ENABLED=true           # Skip duplicates within this run
HASH_DEDUP_AGAINST_TARGET=true    # Also skip if hash already exists in TARGET_DIR (pre-scan)

# Date filter (Sydney local). Leave empty string "" to disable.
# Example: "2025-08-01 00:00:00"
CUTOFF_DATE_SYDNEY="2025-01-01 00:00:00"

# Size filters (bytes). Set to 0 to disable the bound.
MIN_SIZE_BYTES=512                  # e.g. 1024 for 1 KiB; 0 disables min
MAX_SIZE_BYTES=$((1*256*1024))    # 4 MiB; set 0 to disable max

# Extension allow-list (case-insensitive). Empty = no extension filtering.
# Example: EXT_ALLOW=("csv" "tsv")
EXT_ALLOW=("csv" "ods" "odt" "xls" "xlsx" "numbers")

# Filename substring filter (case-insensitive). Empty string = no filter.
# Example: "drug"
FILENAME_SUBSTR=""

# Filename regex filter (extended regex, case-insensitive). Empty = no filter.
# Example: "drug|log|record"
FILENAME_REGEX="drug|log|record|data|good|great|excellent|useful|trip|pihp"

# MIME allow-list. Empty = no MIME filtering.
# Common CSV-ish mimes: text/csv, application/csv, text/plain,
# some producers use application/vnd.ms-excel for CSV.
MIME_ALLOW=()
# MIME_ALLOW=("text/csv" "application/csv" "text/plain" "application/vnd.ms-excel" "text/tab-separated-values")


# ---------------- Header checking mode (choose exactly ONE to 'true') --------
HEADER_MODE_EXACT=false       # Header must match TARGET_HEADER exactly
HEADER_MODE_ANY=true          # Accept any header (no header constraints)
HEADER_MODE_FIRSTWORD=false   # First token of header must equal FIRST_WORD_REQUIRED
HEADER_MODE_AT_LEAST=false    # Header must have at least MIN_HEADER_COLS columns

# Exact header string (only used if HEADER_MODE_EXACT=true)
TARGET_HEADER=""

# First word required (only used if HEADER_MODE_FIRSTWORD=true)
FIRST_WORD_REQUIRED=""

# Minimum header columns (only used if HEADER_MODE_AT_LEAST=true)
MIN_HEADER_COLS=10

# -----------------------------------------------------------------------------

# Sydney timestamp (YYYYMMDDHHMMSS)
now() {
  # Produce UTC then add +10h to format as Sydney (fixed, no DST as per policy)
  # BSD date (macOS): -u for UTC base, -v+10H to add 10 hours
  date -u -v+10H +%Y%m%d%H%M%S
}

log() {
  local msg="$1"
  local line
  line="$(now)  $msg"
  echo "$line"
  if [[ "$LOG_TO_FILE" == true ]]; then
    # Ensure log directory exists
    mkdir -p -- "$(dirname "$LOG_FILE")" || true
    printf '%s\n' "$line" >> "$LOG_FILE"
  fi
}

# Convert a Sydney local "YYYY-MM-DD HH:MM:SS" to UTC epoch seconds
sydney_to_utc_epoch() {
  local s="$1"
  if [[ -z "$s" ]]; then
    echo 0
    return 0
  fi
  # Interpret the input as Sydney local, convert by subtracting 10 hours to UTC
  # Then emit epoch in UTC.
  date -u -j -f "%Y-%m-%d %H:%M:%S" "$s" -v-10H +%s
}

# Lowercase helper
lower() { awk '{print tolower($0)}'; }

# Check if array contains a value (exact match)
in_array() {
  local needle="$1"; shift
  local v
  for v in "$@"; do
    if [[ "$v" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

# Pre-scan target directory to populate known hashes (optional)
declare -a known_hashes=()
if [[ "$HASH_DEDUP_AGAINST_TARGET" == true && -d "$TARGET_DIR" ]]; then
  log "Pre-scanning target for existing hashes…"
  # Only hash regular files up to MAX_SIZE_BYTES (to avoid huge reads if max is set).
  # If MAX_SIZE_BYTES=0 (disabled), hash all.
  while IFS= read -r -d '' f; do
    # Respect MAX_SIZE if set
    if (( MAX_SIZE_BYTES > 0 )); then
      size=$(stat -f '%z' "$f")
      if (( size > MAX_SIZE_BYTES )); then
        continue
      fi
    fi
    h=$(shasum -a 256 "$f" | awk '{print $1}')
    known_hashes+=("$h")
  done < <(find "$TARGET_DIR" -type f -print0 2>/dev/null)
  log "Pre-scan complete: ${#known_hashes[@]} hashes recorded."
fi

# Runtime hash set for this run
declare -a seen_hashes=()

# Prepare cutoff epoch
CUTOFF_EPOCH=0
if [[ -n "$CUTOFF_DATE_SYDNEY" ]]; then
  CUTOFF_EPOCH=$(sydney_to_utc_epoch "$CUTOFF_DATE_SYDNEY")
  log "Cutoff (Sydney) $CUTOFF_DATE_SYDNEY => epoch(UTC) $CUTOFF_EPOCH"
fi

# Ensure target exists if copying
if [[ "$COPY_ENABLED" == true ]]; then
  mkdir -p -- "$TARGET_DIR"
fi

# Validate header mode selection
header_modes_set=0
for flag in "$HEADER_MODE_EXACT" "$HEADER_MODE_ANY" "$HEADER_MODE_FIRSTWORD" "$HEADER_MODE_AT_LEAST"; do
  [[ "$flag" == true ]] && ((header_modes_set++))
done
if (( header_modes_set != 1 )); then
  log "ERROR: Exactly one HEADER_MODE_* must be set to true."
  exit 1
fi

# Candidate file enumeration (start wide; we’ll filter in-process)
# We do not use find -size here because we support both min & max in bytes with stat.
log "Scanning: $SOURCE_DIR"
while IFS= read -r -d '' file; do
  # --------------------- Basic file stats ---------------------
  base=$(basename "$file")
  ext="${base##*.}"
  ext_lc="$(printf '%s' "$ext" | lower)"
  size=$(stat -f '%z' "$file")               # bytes
  birth_epoch=$(stat -f '%B' "$file")        # creation time (UTC epoch)

  # --------------------- Size filter --------------------------
  if (( MIN_SIZE_BYTES > 0 )) && (( size < MIN_SIZE_BYTES )); then
    log "SKIP size < min (${size}B < ${MIN_SIZE_BYTES}B): $file"
    continue
  fi
  if (( MAX_SIZE_BYTES > 0 )) && (( size > MAX_SIZE_BYTES )); then
    log "SKIP size > max (${size}B > ${MAX_SIZE_BYTES}B): $file"
    continue
  fi

  # --------------------- Date filter --------------------------
  if (( CUTOFF_EPOCH > 0 )) && (( birth_epoch <= CUTOFF_EPOCH )); then
    log "SKIP too old (birth ${birth_epoch} <= cutoff ${CUTOFF_EPOCH}): $file"
    continue
  fi

  # --------------------- Extension filter ---------------------
  if ((${#EXT_ALLOW[@]} > 0)); then
    match=false
    for e in "${EXT_ALLOW[@]}"; do
      e_lc="$(printf '%s' "$e" | lower)"
      if [[ "$ext_lc" == "$e_lc" ]]; then match=true; break; fi
    done
    if [[ "$match" == false ]]; then
      log "SKIP ext not allowed (.$ext): $file"
      continue
    fi
  fi

  # --------------------- Filename substring filter -------------
  if [[ -n "$FILENAME_SUBSTR" ]]; then
    if ! printf '%s' "$base" | awk -v pat="$(printf '%s' "$FILENAME_SUBSTR" | lower)" '{if (index(tolower($0), pat)==0) exit 1}'; then
      log "SKIP filename substring miss (${FILENAME_SUBSTR}): $file"
      continue
    fi
  fi

  # --------------------- Filename regex filter -----------------
  if [[ -n "$FILENAME_REGEX" ]]; then
    if ! printf '%s' "$base" | grep -Eiq "$FILENAME_REGEX"; then
      log "SKIP filename regex miss (${FILENAME_REGEX}): $file"
      continue
    fi
  fi

  # --------------------- MIME filter --------------------------
  if ((${#MIME_ALLOW[@]} > 0)); then
    mime=$(file --mime-type -b "$file" 2>/dev/null || echo "unknown/unknown")
    if ! in_array "$mime" "${MIME_ALLOW[@]}"; then
      log "SKIP MIME not allowed ($mime): $file"
      continue
    fi
  fi

  # --------------------- Header processing --------------------
  header="$(awk 'NF {print; exit}' "$file" 2>/dev/null || echo "")"
  if [[ -z "$header" ]]; then
    log "SKIP empty/absent header: $file"
    continue
  fi

  if [[ "$HEADER_MODE_EXACT" == true ]]; then
    if [[ "$header" != "$TARGET_HEADER" ]]; then
      log "SKIP header mismatch (EXACT): $file"
      continue
    fi
  elif [[ "$HEADER_MODE_FIRSTWORD" == true ]]; then
    # First token up to comma or whitespace
    first_token="$(printf '%s' "$header" | sed -E 's/[ ,].*$//' )"
    if [[ "$first_token" != "$FIRST_WORD_REQUIRED" ]]; then
      log "SKIP first-word mismatch (need '$FIRST_WORD_REQUIRED', got '$first_token'): $file"
      continue
    fi
  elif [[ "$HEADER_MODE_AT_LEAST" == true ]]; then
    # Count comma-separated fields
    col_count="$(printf '%s' "$header" | awk -F',' '{print NF}')"
    if [[ -z "$col_count" || "$col_count" -lt "$MIN_HEADER_COLS" ]]; then
      log "SKIP header has only ${col_count:-0} cols (< $MIN_HEADER_COLS): $file"
      continue
    fi
  else
    # HEADER_MODE_ANY => accept as-is
    :
  fi

  # --------------------- Hash duplicate detection --------------
  if [[ "$HASH_DEDUP_ENABLED" == true || "$HASH_DEDUP_AGAINST_TARGET" == true ]]; then
    hash=$(shasum -a 256 "$file" | awk '{print $1}')
    # Check runtime seen
    for h in "${seen_hashes[@]}"; do
      if [[ "$h" == "$hash" ]]; then
        log "SKIP duplicate (this run): $file"
        hash=""
        break
      fi
    done
    # Check pre-known (from TARGET)
    if [[ -n "$hash" && "$HASH_DEDUP_AGAINST_TARGET" == true ]]; then
      for h in "${known_hashes[@]}"; do
        if [[ "$h" == "$hash" ]]; then
          log "SKIP duplicate (already in target): $file"
          hash=""
          break
        fi
      done
    fi
    # Record if still valid
    if [[ -n "$hash" ]]; then
      seen_hashes+=("$hash")
    else
      continue
    fi
  fi

  # --------------------- Copy / Dry-run ------------------------
  if [[ "$COPY_ENABLED" == true ]]; then
    # Prepare destination name with suffix if needed
    name="${base%.*}"
    ext="${base##*.}"
    dest="$TARGET_DIR/$base"
    count=1
    while [[ -e "$dest" ]]; do
      dest="$TARGET_DIR/${name}_$count.$ext"
      ((count++))
    done
    cp -p "$file" "$dest"
    log "COPIED: $file -> $dest"
  else
    log "DRY-RUN (no copy): $file"
  fi

done < <(find "$SOURCE_DIR" -type f -print0 2>/dev/null)

log "✅ Done. Source='$SOURCE_DIR'  Target='${TARGET_DIR}'  Copy=${COPY_ENABLED}"
# =============================================================================
# End of script
# =============================================================================
