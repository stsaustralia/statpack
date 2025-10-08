#!/bin/sh
# merge_csv.sh
# Merges CSV files into one, keeping exactly one header row (from the first file).
# macOS 15.3+ compatible. POSIX sh, no GNU-only dependencies.
# Usage:
#   merge_csv.sh -o OUTPUT.csv file1.csv file2.csv ...
#   merge_csv.sh -o OUTPUT.csv -d /path/to/dir
# Notes:
#   - The first CSV (by argument order, or lexicographic order when using -d) provides the header.
#   - Only files with .csv (case-insensitive) extension are included.
#   - The script preserves contents verbatim; leading zeroes and quotes are unaffected.
#   - Filenames with spaces or other special characters are handled safely.

set -eu

print_usage() {
  cat >&2 <<'EOF'
Usage:
  merge_csv.sh -o OUTPUT.csv file1.csv file2.csv ...
  merge_csv.sh -o OUTPUT.csv -d /path/to/dir

Options:
  -o FILE   Output CSV file (required)
  -d DIR    Read all *.csv files from DIR (non-recursive), sorted by name
  -h        Show this help

Details:
  - Keeps the header from the first CSV only; skips header lines in subsequent CSVs.
  - Preserves bytes of input lines (no number reformatting, no trimming, no locale side-effects).
  - Skips the output file if it appears among inputs.
EOF
}

OUTPUT=""
DIR_MODE=0
DIR_PATH=""

# Parse options
while getopts "o:d:h" opt; do
  case "$opt" in
    o) OUTPUT=$OPTARG ;;
    d) DIR_MODE=1; DIR_PATH=$OPTARG ;;
    h) print_usage; exit 0 ;;
    *) print_usage; exit 2 ;;
  esac
done
shift $((OPTIND - 1))

if [ -z "$OUTPUT" ]; then
  echo "ERROR: -o OUTPUT.csv is required." >&2
  print_usage
  exit 2
fi

# Ensure output directory exists
OUTDIR=$(dirname -- "$OUTPUT")
if [ ! -d "$OUTDIR" ]; then
  echo "ERROR: Output directory does not exist: $OUTDIR" >&2
  exit 1
fi

# Build the list of input files, safely
# We will accumulate them into "$@" using 'set --' so quoting is preserved.
set --  # clear positional parameters

is_csv_ext_ci() {
  # case-insensitive *.csv check using POSIX pattern classes
  # Works even if filename contains spaces
  case "${1##*.}" in
    [cC][sS][vV]) return 0 ;;
    *)            return 1 ;;
  esac
}

if [ "$DIR_MODE" -eq 1 ]; then
  if [ ! -d "$DIR_PATH" ]; then
    echo "ERROR: Directory not found: $DIR_PATH" >&2
    exit 1
  fi

  # Collect and sort entries (non-recursive). We assume filenames do not contain newlines.
  # Use LC_ALL=C for stable byte-wise sorting.
  OLD_LC=${LC_ALL:-}
  LC_ALL=C

  # Build a newline-delimited list, then sort
  FILE_LIST=$(
    # Using printf ensures one entry per line without glob failures on empty dirs
    for f in "$DIR_PATH"/*; do
      [ -e "$f" ] || continue
      if [ -f "$f" ] && is_csv_ext_ci "$f"; then
        # Exclude the output file itself if it sits in the same dir
        if [ "$f" != "$OUTPUT" ]; then
          printf "%s\n" "$f"
        fi
      fi
    done | sort
  )

  LC_ALL=${OLD_LC:-}

  # Add to positional parameters
  # shellcheck disable=SC2162
  IFS='
'
  for f in $FILE_LIST; do
    # Skip if not a regular file at runtime
    [ -f "$f" ] || continue
    set -- "$@" "$f"
  done
  unset IFS
else
  # Positional files mode
  if [ "$#" -lt 1 ]; then
    echo "ERROR: Provide either -d DIR or at least one CSV file." >&2
    print_usage
    exit 2
  fi
  for f in "$@"; do
    if is_csv_ext_ci "$f"; then
      if [ "$f" = "$OUTPUT" ]; then
        echo "NOTICE: Skipping output file listed among inputs: $f" >&2
        continue
      fi
      if [ ! -f "$f" ]; then
        echo "WARNING: Skipping missing file: $f" >&2
        continue
      fi
      # Rebuild "$@" cleanly: we cannot modify "$@" while iterating it directly.
      :
    else
      echo "WARNING: Skipping non-CSV file: $f" >&2
    fi
  done
  # Rebuild "$@" with only valid CSVs (preserving order)
  # We need a second pass to rebuild; capture original into a temp var.
  ORIG_ARGS="$*"
  set --
  IFS='
'
  # shellcheck disable=SC2086
  for f in $ORIG_ARGS; do
    # Put back only valid CSVs that exist and are not the output
    if is_csv_ext_ci "$f"; then
      [ "$f" != "$OUTPUT" ] || { echo "NOTICE: Skipping output file listed among inputs: $f" >&2; continue; }
      [ -f "$f" ] || { echo "WARNING: Skipping missing file: $f" >&2; continue; }
      set -- "$@" "$f"
    fi
  done
  unset IFS
fi

# Ensure we have inputs
if [ "$#" -lt 1 ]; then
  echo "ERROR: No CSV files found to merge." >&2
  exit 1
fi

# Create temporary output to avoid partial writes
TMP_OUT="${OUTPUT}.tmp.$$"

# Use a single awk invocation with all filenames passed as separate, safely quoted arguments via "$@".
# This fixes the earlier bug where unquoted expansion broke paths with spaces.
OLD_LC=${LC_ALL:-}
LC_ALL=C
set +e
awk '
  BEGIN { OFS=""; }
  FNR==1 && NR!=1 { next }  # Skip header line for all but the first file
  { print $0 }
' "$@" > "$TMP_OUT"
AWK_STATUS=$?
set -e
LC_ALL=${OLD_LC:-}

if [ $AWK_STATUS -ne 0 ]; then
  rm -f -- "$TMP_OUT"
  echo "ERROR: awk failed during merge (status '"$AWK_STATUS"')." >&2
  exit 1
fi

# Atomically move temp file into place
mv -f -- "$TMP_OUT" "$OUTPUT"

# Summary
COUNT_FILES=$#
printf "Merged %d CSV file(s) into: %s\n" "$COUNT_FILES" "$OUTPUT"
exit 0