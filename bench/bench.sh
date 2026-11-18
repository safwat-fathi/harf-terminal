#!/bin/zsh
# Run INSIDE the terminal you want to measure; it finds the hosting .app by walking up the parent processes.
# Output loads (three runs each, all runs and the median), the app's CPU seconds during them, then footprint and idle CPU
# (methods: docs/perf.md). Wall time is until the writer has exited, which for a PTY is until the terminal has read
# nearly all of it; it is not "until the last pixel".
# Compare terminals only on the same machine at the same grid size: the `grid:` line records it, and window size changes both
# footprint and redraw cost. Start a fresh instance of each app so no earlier windows are counted.
# Usage: bench/bench.sh <label> [outfile=${TMPDIR:-/tmp}/bench-<label>.txt]
zmodload zsh/datetime
label=${1:-term}; out=${2:-${TMPDIR:-/tmp}/bench-$label.txt}
cpu_s() { ps -o time= -p $1 | awk -F'[:.]' '{n=NF; s=$(n-1)+$n/100; if(n>=3)s+=$(n-2)*60; if(n>=4)s+=$(n-3)*3600; print s}'; }
fp_mb() { footprint $1 2>/dev/null | awk '/Footprint:/{for(i=1;i<=NF;i++)if($i=="Footprint:"){v=$(i+1);u=$(i+2)}; if(u=="KB")v/=1024; if(u=="GB")v*=1024; printf "%.0f",v; exit}'; }
# walk up to the .app process
pid=$$; while [ $pid -gt 1 ]; do
  c=$(ps -o comm= -p $pid); [[ $c == *.app/Contents/MacOS/* ]] && break; pid=$(ps -o ppid= -p $pid | tr -d ' ')
done
app=$pid; echo "app: $(ps -o comm= -p $app) pid=$app" | tee $out
set -- $(stty size </dev/tty)   # rows cols
echo "machine: $(sysctl -n machdep.cpu.brand_string)  macOS $(sw_vers -productVersion)  grid: $2 cols x $1 rows" | tee -a $out
d=${TMPDIR:-/tmp}
f=$d/bench-data.txt; [ -f $f ] || { yes "The quick brown fox jumps over the lazy dog 0123456789" | head -c 50000000 > $f; }
# colour lines come from a file, so the load is the terminal parsing escapes, not zsh running a loop
g=$d/bench-ansi.txt; [ -f $g ] || awk 'BEGIN{for(i=1;i<=200000;i++) printf "\033[3%dmcolor %d\033[0m\n", i%8, i}' > $g
sleep 3
echo "idle_footprint_MB: $(fp_mb $app)" | tee -a $out
c0=$(cpu_s $app)
# t <command> <name>: sends the command's output to the terminal three times; prints every run and the median
t() {
  local -a ts; local s i
  for i in 1 2 3; do s=$EPOCHREALTIME; eval "$1" >/dev/tty; ts+=( $(( EPOCHREALTIME - s )) ); done
  printf "%s: %s median %.2fs\n" "$2" "$(printf '%.2fs ' $ts)" $(print -l $ts | sort -n | sed -n 2p) >&2
}
{ t "seq 1 2000000" "seq_2M_lines"
  t "cat $f" "cat_50MB"
  t "cat $g" "ansi_colors_200k_lines" } 2>&1 | tee -a $out
c1=$(cpu_s $app)
echo "app_cpu_seconds_during_load: $(echo "$c1 $c0" | awk '{printf "%.2f",$1-$2}')" | tee -a $out
echo "loaded_footprint_MB: $(fp_mb $app)" | tee -a $out
clear; sleep 2; ci=$(cpu_s $app); sleep 20; cj=$(cpu_s $app)
echo "idle_cpu_pct_20s: $(echo "$cj $ci" | awk '{printf "%.2f",($1-$2)/20*100}')" | tee -a $out
echo "final_footprint_MB: $(fp_mb $app)" | tee -a $out
