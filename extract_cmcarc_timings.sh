#!/usr/bin/env bash
#
# extract_cmcarc_timings.sh
#
# Extracts every cmcarc archive in a directory (each into its own folder),
# finds the Runmod* text file(s) inside, prints the "OMP_TIMINGS ON PE #0"
# section written by GEM, then draws a bar chart (matplotlib) of the wall
# clock time of each task, averaged over the cmcarc files that were read,
# with error bars of +/- one standard deviation across those files. The input
# directory is shown in the figure title.
#
# A Runmod listing can hold several "OMP_TIMINGS ON PE #0" tables (one for the
# model, one for each I/O server). -T picks the table by its first task.
#
# Usage:
#   extract_cmcarc_timings.sh [options] DIRECTORY
#
#   -T TASK     which timing table to use, given by the first task listed in
#               it: GEMDM (default), IN-server or OUT-server (case-insensitive)
#   -p PATTERN  glob for archive names (default: *.ca)
#   -o OUTDIR   where extracted content goes (default: DIRECTORY/extracted)
#   -g FILE     chart image to write (default: OUTDIR/wallclock_average.png)
#   -t          sort the bars by time instead of keeping GEM's task tree order
#   -N COUNT    show only the COUNT tasks with the largest average wall clock
#               time in the figure, largest first (implies -t)
#   -s          also open the chart in a window
#   -n          no chart, only print the timings
#   -h          help
#
# Compatible with the bash 3.2 that ships with macOS. Needs Python 3 +
# matplotlib for the chart; the interpreter is "python" unless the PYTHON
# environment variable names another one (e.g. PYTHON=python3).

set -u

PATTERN='*.ca'
OUTDIR=''
CHART=''
SORT_BY_TIME=0
TOP_N=''
TABLE_TASK='GEMDM'
SHOW=0
NO_CHART=0
PYTHON="${PYTHON:-python}"

# Line that starts each timing table (matched as plain text, anywhere in the line)
MARKER='__________________OMP_TIMINGS ON PE #0_________________________'

usage() { sed -n '3,31p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while getopts ":T:p:o:g:N:tsnh" opt; do
    case "$opt" in
        T) TABLE_TASK="$OPTARG" ;;
        p) PATTERN="$OPTARG" ;;
        o) OUTDIR="$OPTARG" ;;
        g) CHART="$OPTARG" ;;
        t) SORT_BY_TIME=1 ;;
        N) TOP_N="$OPTARG" ;;
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
# Normalise the spelling of the known table names; any other name is accepted
# as is (matching is case-insensitive) in case GEM adds more tables later.
case "$(printf '%s' "$TABLE_TASK" | tr '[:upper:]' '[:lower:]')" in
    gemdm)      TABLE_TASK='GEMDM' ;;
    in-server)  TABLE_TASK='IN-server' ;;
    out-server) TABLE_TASK='OUT-server' ;;
    '')         echo "Error: -T needs a task name." >&2; exit 1 ;;
    *)          echo "Note: '$TABLE_TASK' is not GEMDM, IN-server or OUT-server;" \
                     "looking for a table that starts with it anyway." >&2 ;;
esac
if [ -n "$TOP_N" ] && ! [[ "$TOP_N" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: -N expects a positive integer (got '$TOP_N')." >&2
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

# Print the PE #0 timing table whose first task is $TABLE_TASK: the marker
# line, the task rows and the closing "_____" line. Each table ends at that
# line, a blank line, or the next TIMINGS section.
# Exit status: 0 = printed, 1 = no PE #0 table at all, 3 = PE #0 table(s) but
# none starting with $TABLE_TASK (a note listing the tables found is printed).
print_timings() {
    awk -v marker="$MARKER" -v want="$TABLE_TASK" '
        function flush(   i) {
            if (inblock) {
                ntab++
                tables = tables (tables == "" ? "" : ", ") (first == "" ? "?" : first)
                if (!printed && tolower(first) == tolower(want)) {
                    for (i = 1; i <= nb; i++) print buf[i]
                    printed = 1
                }
            }
            inblock = 0; nb = 0; first = ""; seen = 0
        }
        index($0, marker) { flush(); inblock = 1; nb = 1; buf[1] = $0; next }
        inblock {
            if ($0 ~ /TIMINGS ON PE/)            { flush(); next }
            if ($0 ~ /^[[:space:]]*$/)           { if (seen) flush(); next }
            if ($0 ~ /^[[:space:]]*_+[[:space:]]*$/) {
                if (seen) { buf[++nb] = $0; flush() }
                next
            }
            # first task row: "...NAME ( ID ) Wall clock= ..."
            if (first == "" && $0 ~ /\([[:space:]]*[0-9]+[[:space:]]*\)[[:space:]]*[Ww][Aa][Ll][Ll]/) {
                name = $0
                sub(/[[:space:]]*\([[:space:]]*[0-9]+[[:space:]]*\).*/, "", name)
                sub(/.*[[:space:].]/, "", name)
                first = name
            }
            seen = 1
            buf[++nb] = $0
        }
        END {
            flush()
            if (printed) exit 0
            if (ntab == 0) exit 1
            print "  (no PE #0 timing table starting with " want "; tables found start with: " tables ")"
            exit 3
        }
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
        print_timings "$runmod"
        rc=$?
        if [ "$rc" -eq 0 ]; then
            if [ -z "$used" ]; then
                used="$runmod"
            else
                echo "  (another Runmod with timings in this archive; only" \
                     "${used#$OUTDIR/} is used for the average)"
            fi
        elif [ "$rc" -eq 1 ]; then
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
    echo "No \"OMP_TIMINGS ON PE #0\" table starting with $TABLE_TASK was found, so no chart." >&2
    chart_status=1
elif ! command -v "$PYTHON" >/dev/null 2>&1; then
    echo "'$PYTHON' not found; skipping the chart (set PYTHON, e.g." \
         "PYTHON=python3 $0 ...)." >&2
    chart_status=1
elif ! "$PYTHON" -c 'import sys; sys.exit(sys.version_info < (3, 6))' >/dev/null 2>&1; then
    echo "'$PYTHON' is not Python 3.6 or newer ($("$PYTHON" -V 2>&1));" \
         "skipping the chart (set PYTHON, e.g. PYTHON=python3 $0 ...)." >&2
    chart_status=1
elif ! "$PYTHON" -c 'import matplotlib' >/dev/null 2>&1; then
    echo "matplotlib not available for $PYTHON; skipping the chart" \
         "(install it with: $PYTHON -m pip install matplotlib)." >&2
    chart_status=1
else
    MARKER="$MARKER" TABLE_TASK="$TABLE_TASK" SORT_BY_TIME="$SORT_BY_TIME" TOP_N="$TOP_N" SHOW="$SHOW" \
    CHART="$CHART" SRC_DIR="$SRC_DIR" "$PYTHON" - "${TIMING_FILES[@]}" <<'PYEOF'
import os
import re
import statistics
import sys

MARKER = os.environ["MARKER"]
TABLE_TASK = os.environ["TABLE_TASK"]
SORT_BY_TIME = os.environ.get("SORT_BY_TIME") == "1"
TOP_N = int(os.environ["TOP_N"]) if os.environ.get("TOP_N") else None
SHOW = os.environ.get("SHOW") == "1"
CHART = os.environ["CHART"]
SRC_DIR = os.environ["SRC_DIR"]

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


def parse_table(path, lines, start):
    """Rows [(key, name, indent_col, seconds)] of the table at lines[start]."""
    rows = []
    for line in lines[start + 1:]:
        line = line.replace("\t", " ").replace("\xa0", " ").rstrip("\r")
        if "TIMINGS ON PE" in line:           # next table
            break
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
    return rows


def parse(path):
    """(rows of the PE #0 table starting with TABLE_TASK, first lines of
    that table or of the first PE #0 table, first task of every table)."""
    with open(path, errors="replace") as f:
        lines = [l.rstrip("\r\n") for l in f]
    starts = [i for i, l in enumerate(lines) if MARKER in l]
    firsts, section = [], lines[starts[0]:starts[0] + 6] if starts else []
    for start in starts:
        rows = parse_table(path, lines, start)
        first = rows[0][1] if rows else "?"
        firsts.append(first)
        if first.lower() == TABLE_TASK.lower():
            return rows, lines[start:start + 6], firsts
    return [], section, firsts


per_file = []
for path in sys.argv[1:]:
    rows, section, firsts = parse(path)
    if rows:
        per_file.append(rows)
    elif any(f != "?" for f in firsts):
        print(f"  (no table starting with {TABLE_TASK} could be read from {path};"
              f" tables found start with: {', '.join(firsts)})", file=sys.stderr)
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
order, names, indent = [], {}, {}
file_values = []                      # one {task: seconds} per file
for rows in per_file:
    this = {}
    for key, name, col, wall in rows:
        if key not in names:
            order.append(key)
            names[key], indent[key] = name, col
        this[key] = this.get(key, 0.0) + wall
    file_values.append(this)

# Per task: one value per cmcarc file read (0 when the task is absent)
samples = {k: [fv.get(k, 0.0) for fv in file_values] for k in order}
seen_in = {k: sum(k in fv for fv in file_values) for k in order}

# Average over the number of cmcarc files read; error = sample standard
# deviation across those files (0 when only one file was read)
avg = {k: sum(samples[k]) / n for k in order}
std = {k: (statistics.stdev(samples[k]) if n > 1 else 0.0) for k in order}

# Nesting level from GEM's indentation (each level is shifted right)
levels = sorted(set(indent.values()))
level = {k: levels.index(indent[k]) for k in order}
label = {k: "  " * level[k] + names[k] for k in order}

width = max(len(label[k]) for k in order) + 6
print(f"{TABLE_TASK} table: wall clock time per task, averaged over {n} cmcarc file(s):")
print(f"Input directory: {SRC_DIR}")
print(f"  {'TASK (ID)'.ljust(width)}  {'AVG WALL (s)':>13}  {'STD DEV (s)':>12}"
      f"  {'MIN (s)':>10}  {'MAX (s)':>10}")
for k in order:
    tag = f"{label[k]} ({k.rsplit('(', 1)[1]}"
    note = "" if seen_in[k] == n else f"   (in {seen_in[k]}/{n} files)"
    print(f"  {tag.ljust(width)}  {avg[k]:13.4f}  {std[k]:12.4f}"
          f"  {min(samples[k]):10.4f}  {max(samples[k]):10.4f}{note}")
print()

# Horizontal bars; first task (GEMDM) at the top
if TOP_N is not None:
    # the TOP_N tasks with the largest average wall clock time, largest first
    keys = sorted(order, key=lambda k: avg[k], reverse=True)[:TOP_N]
elif SORT_BY_TIME:
    keys = sorted(order, key=lambda k: avg[k], reverse=True)
else:
    keys = order
# tree indentation only makes sense in GEM's own order
tree_order = TOP_N is None and not SORT_BY_TIME
ylabel = {k: (label[k] if tree_order else names[k]) for k in keys}
keys = list(reversed(keys))           # barh draws bottom-up
values = [avg[k] for k in keys]
errors = [std[k] for k in keys]
colors = ["#1f4e79", "#3b6ea5", "#6c9bd2", "#a7c4e5"]

fig, ax = plt.subplots(figsize=(11, max(3.5, 0.28 * len(keys) + 1.6)))
ax.barh(range(len(keys)), values,
        color=[colors[min(level[k], len(colors) - 1)] for k in keys],
        xerr=errors, error_kw=dict(ecolor="#333333", elinewidth=0.9,
                                   capsize=2.5, capthick=0.9))
ax.set_yticks(range(len(keys)))
# left-aligned monospace labels so the tree indentation shows
ax.set_yticklabels([ylabel[k] for k in keys], fontfamily="monospace", fontsize=8,
                   ha="left")
ax.tick_params(axis="y", pad=4.9 * max(len(ylabel[k]) for k in keys) + 6)
# value labels just past the end of each error bar
xmax = max(v + e for v, e in zip(values, errors)) or 1.0
for y, (v, e) in enumerate(zip(values, errors)):
    text = f"{v:.3g} ± {e:.2g}" if n > 1 else f"{v:.3g}"
    ax.text(v + e + 0.01 * xmax, y, text, va="center", fontsize=7)
ax.set_xlim(0, xmax * 1.18)
ax.set_ylim(-0.6, len(keys) - 0.4)
ax.set_xlabel("Wall clock time (s)")
plural = "s" if n != 1 else ""
# keep the end of very long paths (the most specific part) so the title fits
shown_dir = SRC_DIR if len(SRC_DIR) <= 110 else "…" + SRC_DIR[-109:]
top_note = (f"top {len(keys)} of {len(order)} tasks, "
            if TOP_N is not None and len(keys) < len(order) else "")
err_note = ", error bars = ±1 standard deviation" if n > 1 else ""
ax.set_title(f"GEM OMP timings on PE #0, {TABLE_TASK} table: "
             f"average wall clock time per task\n"
             f"Input directory: {shown_dir}\n"
             f"({top_note}{n} cmcarc file{plural}{err_note})", fontsize=10)
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
