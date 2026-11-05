#!/usr/bin/env bash
#
# extract_cmcarc_timings.sh
#
# Extracts every cmcarc archive in a directory (each into its own folder),
# finds the Runmod* text file(s) inside, and prints the
# "OMP TIMINGS ON PE #0" section.
#
# Usage:
#   extract_cmcarc_timings.sh [-p PATTERN] [-o OUTDIR] DIRECTORY
#
#   -p PATTERN  glob for archive names (default: *.cmcarc)
#   -o OUTDIR   where extracted content goes (default: DIRECTORY/extracted)
#   -h          help
#
# Compatible with the bash 3.2 that ships with macOS.

set -u

PATTERN='*.cmcarc'
OUTDIR=''
MARKER='OMP TIMINGS ON PE #0'

usage() { sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while getopts ":p:o:h" opt; do
    case "$opt" in
        p) PATTERN="$OPTARG" ;;
        o) OUTDIR="$OPTARG" ;;
        h) usage 0 ;;
        :) echo "Option -$OPTARG needs an argument." >&2; usage 1 ;;
        \?) echo "Unknown option -$OPTARG" >&2; usage 1 ;;
    esac
done
shift $((OPTIND - 1))

[ $# -eq 1 ] || usage 1
SRC_DIR="$1"

if [ ! -d "$SRC_DIR" ]; then
    echo "Error: '$SRC_DIR' is not a directory." >&2
    exit 1
fi
if ! command -v cmcarc >/dev/null 2>&1; then
    echo "Error: 'cmcarc' not found in PATH." >&2
    exit 1
fi

# Absolute paths, so we can cd around safely
SRC_DIR="$(cd "$SRC_DIR" && pwd)"
[ -n "$OUTDIR" ] || OUTDIR="$SRC_DIR/extracted"
mkdir -p "$OUTDIR" || exit 1
OUTDIR="$(cd "$OUTDIR" && pwd)"

# Print the timing block: from the marker line until the first blank line
# that follows some content (the end of the table).
print_timings() {
    awk -v marker="$MARKER" '
        index($0, marker) { found = 1; inblock = 1; seen = 0 }
        inblock {
            if ($0 ~ /^[[:space:]]*$/) {
                if (seen) { inblock = 0; print ""; next }
            } else if (!index($0, marker)) {
                seen = 1
            }
            print
        }
        END { exit(found ? 0 : 1) }
    ' "$1"
}

n_archives=0
failed=''

shopt -s nullglob
for archive in "$SRC_DIR"/$PATTERN; do
    [ -f "$archive" ] || continue
    n_archives=$((n_archives + 1))

    name="$(basename "$archive")"
    dest="$OUTDIR/${name%.*}"
    mkdir -p "$dest"

    echo "=================================================================="
    echo "Archive: $name"
    echo "=================================================================="

    # cmcarc extracts into the current directory, so run it from $dest
    if ! ( cd "$dest" && cmcarc -x -f "$archive" ) ; then
        echo "  !! cmcarc failed on $name" >&2
        failed="$failed $name"
        echo
        continue
    fi

    found_runmod=0
    while IFS= read -r runmod; do
        found_runmod=1
        echo "--- ${runmod#$OUTDIR/}"
        if ! print_timings "$runmod"; then
            echo "  (no \"$MARKER\" section in this file)"
        fi
        echo
    done < <(find "$dest" -type f -name 'Runmod*' | sort)

    if [ "$found_runmod" -eq 0 ]; then
        echo "  (no Runmod* file found in this archive)"
        echo
    fi
done
shopt -u nullglob

if [ "$n_archives" -eq 0 ]; then
    echo "No files matching '$PATTERN' in $SRC_DIR" >&2
    exit 1
fi

echo "Processed $n_archives archive(s). Extracted content is in: $OUTDIR"
if [ -n "$failed" ]; then
    echo "Failed to extract:$failed" >&2
    exit 2
fi
