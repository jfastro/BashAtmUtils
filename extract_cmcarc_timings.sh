#!/usr/bin/env bash
#
# extract_cmcarc_timings.sh
#
# Extracts every cmcarc archive in a directory (each into its own folder),
# finds the Runmod* text file(s) inside, prints the "OMP TIMINGS ON PE #0"
# section, then draws a bar chart (matplotlib) of the wall clock time of each
# task, averaged over the cmcarc files that were read.
#
# Usage:
#   extract_cmcarc_timings.sh [options] DIRECTORY
#
#   -p PATTERN  glob for archive names (default: *.cmcarc)
#   -o OUTDIR   where extracted content goes (default: DIRECTORY/extracted)
#   -g FILE     chart image to write (default: OUTDIR/wallclock_average.png)
#   -c N        use the N-th number on each task row (1 = first, counting any
#               index/ID numbers) as the wall clock time, instead of locating
#               it from the "wall" heading of the table
#   -s          also open the chart in a window
#   -n          no chart, only print the timings
#   -h          help
#
# Compatible with the bash 3.2 that ships with macOS. Needs python3 + matplotlib
# for the chart.

set -u

PATTERN='*.cmcarc'
OUTDIR=''
CHART=''
WALL_COL=''
SHOW=0
NO_CHART=0
MARKER='OMP TIMINGS ON PE #0'
PYTHON="${PYTHON:-python3}"

usage() { sed -n '3,24p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while getopts ":p:o:g:c:snh" opt; do
    case "$opt" in
        p) PATTERN="$OPTARG" ;;
        o) OUTDIR="$OPTARG" ;;
        g) CHART="$OPTARG" ;;
        c) WALL_COL="$OPTARG" ;;
        s) SHOW=1 ;;
        n) NO_CHART=1 ;;
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
if [ -n "$WALL_COL" ] && ! [[ "$WALL_COL" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: -c expects a positive integer." >&2
    exit 1
fi

# Absolute paths, so we can cd around safely
SRC_DIR="$(cd "$SRC_DIR" && pwd)"
[ -n "$OUTDIR" ] || OUTDIR="$SRC_DIR/extracted"
mkdir -p "$OUTDIR" || exit 1
OUTDIR="$(cd "$OUTDIR" && pwd)"
[ -n "$CHART" ] || CHART="$OUTDIR/wallclock_average.png"

# Print the timing block: from the marker line until the first blank line
# that comes after a line holding numbers (i.e. the end of the table rows),
# or until another "TIMINGS ON PE" section starts.
print_timings() {
    awk -v marker="$MARKER" '
        index($0, marker) { found = 1; inblock = 1; seen = 0; print; next }
        inblock && /TIMINGS ON PE/ { inblock = 0 }
        inblock {
            if ($0 ~ /^[[:space:]]*$/) {
                if (seen) { inblock = 0; print ""; next }
            } else if ($0 ~ /[0-9]/) {
                seen = 1
            }
            print
        }
        END { exit(found ? 0 : 1) }
    ' "$1"
}

n_archives=0
failed=''
TIMING_FILES=()     # one Runmod file per archive, used for the average

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
    used=''
    while IFS= read -r runmod; do
        found_runmod=1
        echo "--- ${runmod#$OUTDIR/}"
        if print_timings "$runmod"; then
            if [ -z "$used" ]; then
                used="$runmod"
            else
                echo "  (another Runmod with timings in this archive; only" \
                     "${used#$OUTDIR/} is used for the average)"
            fi
        else
            echo "  (no \"$MARKER\" section in this file)"
        fi
        echo
    done < <(find "$dest" -type f -name 'Runmod*' | sort)

    if [ "$found_runmod" -eq 0 ]; then
        echo "  (no Runmod* file found in this archive)"
        echo
    fi
    [ -n "$used" ] && TIMING_FILES+=("$used")
done
shopt -u nullglob

if [ "$n_archives" -eq 0 ]; then
    echo "No files matching '$PATTERN' in $SRC_DIR" >&2
    exit 1
fi

echo "Processed $n_archives archive(s). Extracted content is in: $OUTDIR"
echo

# ---------------------------------------------------------------------------
# Average wall clock time per task + bar chart
# ---------------------------------------------------------------------------
chart_status=0
if [ "$NO_CHART" -eq 1 ]; then
    :
elif [ "${#TIMING_FILES[@]}" -eq 0 ]; then
    echo "No timing sections found, so no chart." >&2
    chart_status=1
elif ! "$PYTHON" -c 'import matplotlib' >/dev/null 2>&1; then
    echo "matplotlib not available for $PYTHON; skipping the chart" \
         "(install it with: $PYTHON -m pip install matplotlib)." >&2
    chart_status=1
else
    MARKER="$MARKER" WALL_COL="$WALL_COL" SHOW="$SHOW" CHART="$CHART" \
    "$PYTHON" - "${TIMING_FILES[@]}" <<'PYEOF'
import os
import re
import sys

MARKER = os.environ["MARKER"]
WALL_COL = int(os.environ["WALL_COL"]) if os.environ.get("WALL_COL") else None
SHOW = os.environ.get("SHOW") == "1"
CHART = os.environ["CHART"]

import matplotlib
if not SHOW:
    matplotlib.use("Agg")
import matplotlib.pyplot as plt

NUM = re.compile(r"[-+]?(?:\d+\.\d*|\.\d+|\d+)(?:[eEdD][-+]?\d+)?")
TOKEN = re.compile(r"\S+")
PUNCT = re.compile(r"^[\[\]():|=]+$")


def timing_block(path):
    """Lines of the marker section, using the same end rule as the shell part."""
    with open(path, errors="replace") as f:
        lines = f.read().splitlines()
    for i, line in enumerate(lines):
        if MARKER in line:
            break
    else:
        return []
    block, seen = [], False
    for line in lines[i + 1:]:
        if "TIMINGS ON PE" in line:
            break
        if not line.strip():
            if seen:
                break
            continue
        if re.search(r"\d", line):
            seen = True
        block.append(line)
    return block


def header_span(block):
    """(start, end) columns of the 'wall ...' heading, or None."""
    for line in block:
        m = re.search(r"wall", line, re.I)
        if m and not NUM.fullmatch(line.split()[-1] if line.split() else ""):
            # heading text runs until two consecutive spaces
            end = line.find("  ", m.start())
            return m.start(), (len(line) if end < 0 else end)
    return None


def parse(path):
    block = timing_block(path)
    span = header_span(block)
    tasks = []           # [(name, seconds)], in file order
    for line in block:
        # strip brackets/colons so "[  1]" or "1:" count as plain numbers
        tokens = [(t.group().strip("[]():,;|"), t.start(), t.end())
                  for t in TOKEN.finditer(line)]
        tokens = [t for t in tokens if t[0]]
        nums = [t for t in tokens if NUM.fullmatch(t[0])]
        words = [t[0] for t in tokens if t not in nums and not PUNCT.match(t[0])]
        if not nums or not words or set(line.strip()) <= set("_-=*+ "):
            continue
        if WALL_COL is not None:
            if WALL_COL > len(nums):
                continue
            pick = nums[WALL_COL - 1]
        elif span is not None:
            hs, he = span
            # numeric field closest to (or under) the wall clock heading
            pick = min(nums, key=lambda t: max(0, hs - t[2], t[1] - he))
        else:
            # no heading: first value with a decimal point, else the last value
            dec = [t for t in nums if "." in t[0]]
            pick = dec[0] if dec else nums[-1]
        value = float(pick[0].replace("d", "e").replace("D", "e"))
        tasks.append((" ".join(words), value))
    return tasks, span


per_file = []
for path in sys.argv[1:]:
    tasks, span = parse(path)
    if not tasks:
        print(f"  (could not read any task rows from {path})", file=sys.stderr)
        continue
    if span is None and WALL_COL is None:
        print(f"  (no 'wall' heading found in {os.path.basename(path)}; "
              f"guessed the column - use -c N to choose it)", file=sys.stderr)
    # make repeated task names unique within one file (name, name #2, ...)
    count, unique = {}, []
    for name, val in tasks:
        count[name] = count.get(name, 0) + 1
        unique.append((name if count[name] == 1 else f"{name} #{count[name]}", val))
    per_file.append(unique)

if not per_file:
    print("No task timings could be parsed; no chart.", file=sys.stderr)
    sys.exit(1)

n = len(per_file)
order, totals, seen_in = [], {}, {}
for tasks in per_file:
    for name, val in tasks:
        if name not in totals:
            order.append(name)
            totals[name] = 0.0
            seen_in[name] = 0
        totals[name] += val
        seen_in[name] += 1

# Average over the number of cmcarc files read
avg = {name: totals[name] / n for name in order}

width = max(len(s) for s in order)
print(f"Wall clock time per task, averaged over {n} cmcarc file(s):")
print(f"  {'TASK'.ljust(width)}  {'AVG WALL (s)':>14}")
for name in order:
    note = "" if seen_in[name] == n else f"   (in {seen_in[name]}/{n} files)"
    print(f"  {name.ljust(width)}  {avg[name]:14.3f}{note}")
print()

# Horizontal bars, largest at the top
names = sorted(order, key=lambda k: avg[k])
values = [avg[k] for k in names]
fig, ax = plt.subplots(figsize=(10, max(3.0, 0.32 * len(names) + 1.5)))
bars = ax.barh(names, values, color="#3b6ea5")
ax.bar_label(bars, labels=[f"{v:.2f}" for v in values], padding=3, fontsize=8)
ax.set_xlabel("Wall clock time (s)")
ax.set_title(f"Average wall clock time per task ({MARKER}), {n} file(s)")
ax.margins(x=0.12)
ax.grid(axis="x", alpha=0.3)
ax.set_axisbelow(True)
fig.tight_layout()
fig.savefig(CHART, dpi=150)
print(f"Chart written to: {CHART}")
if SHOW:
    plt.show()
PYEOF
    chart_status=$?
fi

if [ -n "$failed" ]; then
    echo "Failed to extract:$failed" >&2
    exit 2
fi
exit "$chart_status"
