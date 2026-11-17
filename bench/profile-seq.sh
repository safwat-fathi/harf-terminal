#!/bin/sh
# Profiles an output flood (`seq 1 N`) through the real app. Launches its own instance and tracks that pid only (it only
# ever kills the pid it started); the flood runs as the child (HARF_CHILD_CMD), macOS `sample` watches the app for 2 s, and
# the flood's wall time, the app's CPU seconds, and the main thread's share of time in the wake path's change detection
# (`TerminalController.invalidateChangedRows`) are printed, then the top frames. The raw `sample` report is kept in OUT.
# The result depends on the grid, because redraw work scales with the number of cells: HARF_CONTENT_SIZE=WxH pins the
# window (700x420 is the 80x24 class, see docs/perf.md); the grid the child saw is printed.
# `sample` suspends the app's threads every millisecond, so it slows the flood while it runs: compare flood times only between
# runs with the same SAMPLE_SECONDS, and take a clean time with SAMPLE_SECONDS=0 (no profile, just the flood time and CPU).
# Usage: [HARF_CONTENT_SIZE=WxH] [N=2000000] [SAMPLE_SECONDS=2] [APP=<Harf binary>] bench/profile-seq.sh [out=${TMPDIR:-/tmp}/harf-profile-seq.txt]
set -eu
N=${N:-2000000}
SECS=${SAMPLE_SECONDS:-2}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP=${APP:-$ROOT/macos/.build/Harf.app/Contents/MacOS/Harf}
OUT=${1:-${TMPDIR:-/tmp}/harf-profile-seq.txt}
[ -x "$APP" ] || { echo "build the app first: macos/build-app.sh" >&2; exit 1; }
D=$(mktemp -d "${TMPDIR:-/tmp}/harf-profile-seq.XXXXXX")
cat > "$D/flood.sh" <<EOF
sleep 2
stty size > "$D/grid"
perl -MTime::HiRes=time -e 'printf "%.3f\n", time' > "$D/start"
seq 1 $N
perl -MTime::HiRes=time -e 'printf "%.3f\n", time' > "$D/end"
EOF
cpu_s() { ps -o time= -p "$1" | awk -F'[:.]' '{n=NF; s=$(n-1)+$n/100; if(n>=3)s+=$(n-2)*60; print s}'; }


# Launched through Launch Services (`open -n`): AppKit opens the first window on its "open application" event, which a binary
# started directly from some contexts (an agent's shell, ssh) never gets, so no window opens and the child never runs. The pid
# is the one that was not there before; only that pid is ever killed. `-n` makes a new instance even if Harf is running.
BUNDLE=${APP%/Contents/MacOS/*}
pgrep -f "$APP\$" | sort > "$D/before" || true
PID=
trap '[ -z "$PID" ] || kill "$PID" 2>/dev/null; rm -rf "$D"' EXIT
open -n "$BUNDLE" --env HARF_CHILD_CMD="sh $D/flood.sh" ${HARF_CONTENT_SIZE:+--env HARF_CONTENT_SIZE="$HARF_CONTENT_SIZE"}
i=0; while [ -z "$PID" ] && [ $i -lt 100 ]; do
  PID=$(pgrep -f "$APP\$" | grep -vxF -f "$D/before" | head -1 || true); sleep 0.1; i=$((i + 1))
done
[ -n "$PID" ] || { echo "Harf did not start" >&2; exit 1; }
i=0; while [ ! -s "$D/start" ] && [ $i -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
[ -s "$D/start" ] || { echo "the flood did not start within 30 s" >&2; exit 1; }
cpu0=$(cpu_s "$PID")
sleep 0.5   # past the first redraws, inside the flood
if [ "$SECS" -gt 0 ]; then
  sample "$PID" "$SECS" -file "$OUT" >/dev/null 2>&1 || { echo "sample failed (is the process still running?)" >&2; exit 1; }
fi
i=0; while [ ! -s "$D/end" ] && [ $i -lt 1200 ]; do sleep 0.5; i=$((i + 1)); done
[ -s "$D/end" ] || { echo "the flood did not finish within 10 minutes" >&2; exit 1; }
cpu1=$(cpu_s "$PID")

echo "machine=$(sysctl -n machdep.cpu.brand_string) macOS=$(sw_vers -productVersion) commit=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo ?) grid(rows cols)=$(cat "$D/grid") window=${HARF_CONTENT_SIZE:-default}"
awk -v s="$(cat "$D/start")" -v e="$(cat "$D/end")" -v n="$N" -v a="$cpu0" -v b="$cpu1" -v secs="$SECS" 'BEGIN { t = e - s; printf "flood: seq 1 %d took %.2f s; app cpu %.2f s\n", n, t, b - a; if (secs > 0 && t < secs + 0.6) print "warning: the flood is shorter than the sample; raise N" }'
if [ "$SECS" -gt 0 ]; then
awk '
  /^ +[0-9]+ Thread_/ { inmain = (/ Main Thread/ || /com.apple.main-thread/); if (inmain) { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) { mt = $i; break } } }
  inmain && /TerminalController.invalidateChangedRows\(\)/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) { ic += $i; break } }
  END { printf "main thread: %d samples, %d inside invalidateChangedRows (%.0f%%)\n", mt, ic, mt ? 100 * ic / mt : 0 }' "$OUT"
echo "top of stack, all threads (a parser thread waiting on the session lock shows as __psynch_mutexwait):"
awk '/^Sort by top of stack/ { on = 1; next } on && NF && !/__workq_kernreturn|mach_msg2_trap|kevent|__semwait|  poll  / && n++ < 8' "$OUT"
echo "full report: $OUT"
fi
