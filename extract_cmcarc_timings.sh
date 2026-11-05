#!/usr/bin/env bash
#
# extract_cmcarc_timings.sh
#
# Extracts every cmcarc archive in a directory (each into its own folder),
# finds the Runmod* text file(s) inside, prints the "OMP_TIMINGS ON PE #0"
# section written by GEM, then draws a bar chart (matplotlib) of the wall
# clock time of each task, averaged over the cmcarc files that were read.
#
# Usage:
#   extract_cmcarc_timings.sh [options] DIRECTORY
#
#   -p PATTERN  glob for archive names (default: *.cmcarc)
#   -o OUTDIR   where extracted content goes (default: DIRECTORY/extracted)
#   -g FILE     chart image to write (default: OUTDIR/wallclock_average.png)
#   -t          sort the bars by time instead of keeping GEM's task tree order
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
SORT_BY_TIME=0
SHOW=0
NO_CHART=0
PYTHON="${PYTHON:-python3}"

# GEM writes "OMP_TIMINGS ON PE #0"; also accept a space instead of "_"
MARKER_RE='OMP[ _]TIMINGS ON PE #0'

usage() { sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while getopts ":p:o:g:tsnh" opt; do
    case "$opt" in
        p) PATTERN="$OPTARG" ;;
        o) OUTDIR="$OPTARG" ;;
        g) CHART="$OPTARG" ;;
        t) SORT_BY_TIME=1 ;;
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

# Absolute paths, so we can cd around safely
SRC_DIR="$(cd "$SRC_DIR" && pwd)"
[ -n "$OUTDIR" ] || OUTDIR="$SRC_DIR/extracted"
mkdir -p "$OUTDIR" || exit 1
OUTDIR="$(cd "$OUTDIR" && pwd)"
[ -n "$CHART" ] || CHART="$OUTDIR/wallclock_average.png"

# Print the timing block: the marker line, the task rows, and the closing
# "_____" line (or stop at a blank line / another TIMINGS section).
print_timings() {
    awk -v re="$MARKER_RE" '
        !inblock && $0 ~ re { found = 1; inblock = 1; seen = 0; print; next }
        inblock {
            if ($0 ~ /TIMINGS ON PE/)        { inblock = 0; next }
            if ($0 ~ /^[[:space:]]*$/)       { if (seen) inblock = 0; next }
            if ($0 ~ /^[[:space:]]*_+[[:space:]]*$/) {
                if (seen) { print; inblock = 0 }
                next
            }
            seen = 1
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
            echo "  (no \"OMP_TIMINGS ON PE #0\" section in this file)"
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
    MARKER_RE="$MARKER_RE" SORT_BY_TIME="$SORT_BY_TIME" SHOW="$SHOW" \
    CHART="$CHART" "$PYTHON" - "${TIMING_FILES[@]}" <<'PYEOF'
import os
import re
import sys

MARKER = re.compile(os.environ["MARKER_RE"])
SORT_BY_TIME = os.environ.get("SORT_BY_TIME") == "1"
SHOW = os.environ.get("SHOW") == "1"
CHART = os.environ["CHART"]

import matplotlib
if not SHOW:
    matplotlib.use("Agg")
import matplotlib.pyplot as plt

# A GEM timing row, e.g.
#  18.72%      .........DYNSTEP ( 10)   Wall clock=  1.278908E+01  count=       14
# Only "NAME ( ID ) Wall clock= VALUE" is required; whatever comes before the
# name (percentage, which can be NaN or ****, and the dots) is ignored.
ROW = re.compile(
    r"^(?P<lead>.*?)(?P<dots>\.*)(?P<name>[^\s.(][^\s(]*)\s*\(\s*(?P<id>\d+)\s*\)"
    r"\s*wall\s*clock\s*[=:]\s*(?P<wall>\S+)",
    re.IGNORECASE,
)
END = re.compile(r"^\s*(_+)?\s*$|TIMINGS ON PE")


def to_float(text):
    try:
        return float(text.replace("D", "E").replace("d", "e"))
    except ValueError:
        return None


def parse(path):
    """([(key, name, indent_col, seconds)], first lines of the section)."""
    with open(path, errors="replace") as f:
        lines = [l.rstrip("\r\n") for l in f]
    start = next((i for i, l in enumerate(lines) if MARKER.search(l)), None)
    if start is None:
        return [], []
    section = lines[start:start + 6]
    rows = []
    for line in lines[start + 1:]:
        line = line.replace("\t", " ").replace("\xa0", " ").rstrip("\r")
        m = ROW.match(line)
        if not m:
            if rows and END.search(line):     # end of the table
                break
            continue
        wall = to_float(m.group("wall"))
        if wall is None:
            print(f"  (unreadable wall clock '{m.group('wall')}' for "
                  f"{m.group('name')} in {os.path.basename(path)}; skipped)",
                  file=sys.stderr)
            continue
        key = f"{m.group('name')} ({int(m.group('id'))})"
        rows.append((key, m.group("name"), m.start("dots"), wall))
    return rows, section


per_file = []
for path in sys.argv[1:]:
    rows, section = parse(path)
    if rows:
        per_file.append(rows)
    else:
        print(f"  (could not read any task rows from {path})", file=sys.stderr)
        print("   First lines of its timing section (please send these):",
              file=sys.stderr)
        for l in section:
            print(f"   | {l!r}", file=sys.stderr)

if not per_file:
    print("No task timings could be parsed; no chart.", file=sys.stderr)
    sys.exit(1)

n = len(per_file)
order, names, indent, totals, seen_in = [], {}, {}, {}, {}
for rows in per_file:
    for key, name, col, wall in rows:
        if key not in totals:
            order.append(key)
            names[key], indent[key] = name, col
            totals[key], seen_in[key] = 0.0, 0
        totals[key] += wall
        seen_in[key] += 1

# Average over the number of cmcarc files read
avg = {k: totals[k] / n for k in order}

# Nesting level from GEM's indentation (each level is shifted right)
levels = sorted(set(indent.values()))
level = {k: levels.index(indent[k]) for k in order}
label = {k: "  " * level[k] + names[k] for k in order}

width = max(len(label[k]) for k in order) + 6
print(f"Wall clock time per task, averaged over {n} cmcarc file(s):")
print(f"  {'TASK (ID)'.ljust(width)}  {'AVG WALL (s)':>13}")
for k in order:
    tag = f"{label[k]} ({k.rsplit('(', 1)[1]}"
    note = "" if seen_in[k] == n else f"   (in {seen_in[k]}/{n} files)"
    print(f"  {tag.ljust(width)}  {avg[k]:13.4f}{note}")
print()

# Horizontal bars; first task (GEMDM) at the top
keys = sorted(order, key=lambda k: avg[k], reverse=True) if SORT_BY_TIME else order
keys = list(reversed(keys))           # barh draws bottom-up
values = [avg[k] for k in keys]
colors = ["#1f4e79", "#3b6ea5", "#6c9bd2", "#a7c4e5"]

fig, ax = plt.subplots(figsize=(11, max(3.5, 0.28 * len(keys) + 1.6)))
bars = ax.barh(range(len(keys)), values,
               color=[colors[min(level[k], len(colors) - 1)] for k in keys])
ax.set_yticks(range(len(keys)))
# left-aligned monospace labels so the tree indentation shows
ax.set_yticklabels([label[k] for k in keys], fontfamily="monospace", fontsize=8,
                   ha="left")
ax.tick_params(axis="y", pad=4.9 * max(len(label[k]) for k in keys) + 6)
ax.bar_label(bars, labels=[f"{v:.3g}" for v in values], padding=3, fontsize=7)
ax.set_ylim(-0.6, len(keys) - 0.4)
ax.set_xlabel("Wall clock time (s)")
ax.set_title(f"GEM OMP timings on PE #0: average wall clock time per task "
             f"({n} cmcarc file{'s' if n != 1 else ''})")
ax.margins(x=0.08)
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
