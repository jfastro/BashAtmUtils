#!/usr/bin/env bash
#
# gen_dates.sh - generate a series of dates in yyyymmddhh format
#
# Usage: gen_dates.sh START COUNT INCREMENT
#   START      start date, format yyyymmddhh (e.g. 2026110400)
#   COUNT      number of dates to output (the start date counts as the first)
#   INCREMENT  hours between consecutive dates (may be negative)
#
# Example: gen_dates.sh 2026103118 4 6
#   2026103118
#   2026110100
#   2026110106
#   2026110112
#
# Times are treated as UTC, so daylight-saving changes never skip or
# repeat an hour. Requires GNU date (on macOS: install coreutils, use gdate).

set -euo pipefail

usage() {
    echo "Usage: $(basename "$0") START(yyyymmddhh) COUNT INCREMENT_HOURS" >&2
    exit 1
}

[[ $# -eq 3 ]] || usage

start=$1
count=$2
incr=$3

# --- Validate input -----------------------------------------------------------
[[ $start =~ ^[0-9]{10}$ ]] || { echo "Error: START must be yyyymmddhh" >&2; exit 1; }
[[ $count =~ ^[0-9]+$ ]]    || { echo "Error: COUNT must be a non-negative integer" >&2; exit 1; }
[[ $incr  =~ ^-?[0-9]+$ ]]  || { echo "Error: INCREMENT must be an integer" >&2; exit 1; }

# Pick GNU date (gdate on macOS if available)
DATE=date
command -v gdate >/dev/null 2>&1 && DATE=gdate

yyyy=${start:0:4}
mm=${start:4:2}
dd=${start:6:2}
hh=${start:8:2}

# Convert start to seconds since epoch (also validates the date itself)
if ! start_epoch=$(TZ=UTC $DATE -d "${yyyy}-${mm}-${dd} ${hh}:00:00" +%s 2>/dev/null); then
    echo "Error: invalid date '$start'" >&2
    exit 1
fi

# Reject things like hour 25 that date may silently accept/normalise
if [[ $(TZ=UTC $DATE -d "@$start_epoch" +%Y%m%d%H) != "$start" ]]; then
    echo "Error: invalid date '$start'" >&2
    exit 1
fi

# --- Generate the series ------------------------------------------------------
for (( i = 0; i < count; i++ )); do
    t=$(( start_epoch + i * incr * 3600 ))
    TZ=UTC $DATE -d "@$t" +%Y%m%d%H
done
