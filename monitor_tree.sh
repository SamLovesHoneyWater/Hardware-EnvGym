#!/bin/bash
# 监控进程树总 RSS 峰值（tutorial: 整棵树而非单进程）
# 用法: monitor_tree.sh <root_pid> <outfile>
# 输出: <outfile>.peaks 含 PEAK_RAM_KB, PEAK_RAM_GB, RUNTIME_SECONDS
# 优先按进程组(PGID)汇总，避免父子链在子 shell/conda 下漏采；为 0 时回退到树遍历

ROOT_PID=$1
OUTFILE=$2
ROOT_PGID=$3
INTERVAL=0.5

get_descendants() {
  local ppid=$1
  ps -eo ppid,pid 2>/dev/null | awk -v p="$ppid" '$1+0==p+0 {print $2}'
}

tree_pids() {
  local root=$1
  echo "$root"
  local children
  children=$(get_descendants "$root")
  for c in $children; do
    tree_pids "$c"
  done
}

# 按进程组汇总 RSS（( cmd ) & 与子进程通常同属一个 PGID，更稳）
pgid_rss_kb() {
  local root=$1
  local pgid
  if [ -n "$ROOT_PGID" ]; then
    pgid="$ROOT_PGID"
  else
    pgid=$(ps -o pgid= -p "$root" 2>/dev/null | tr -d ' ')
  fi
  [ -z "$pgid" ] && echo 0 && return
  local total=0
  local rss
  while read -r pid _; do
    [ -z "$pid" ] && continue
    if [ -d "/proc/$pid" ] 2>/dev/null; then
      rss=$(grep -E '^VmRSS:' /proc/$pid/status 2>/dev/null | awk '{print $2}')
      [ -n "$rss" ] && total=$((total + rss))
    fi
  done < <(ps -eo pid,pgid 2>/dev/null | awk -v g="$pgid" 'NR>1 && $2+0==g+0 {print $1, $2}')
  echo $total
}

pgid_alive() {
  local root=$1
  local pgid
  if [ -n "$ROOT_PGID" ]; then
    pgid="$ROOT_PGID"
  else
    pgid=$(ps -o pgid= -p "$root" 2>/dev/null | tr -d ' ')
  fi
  [ -z "$pgid" ] && return 1
  ps -eo pgid 2>/dev/null | awk -v g="$pgid" 'NR>1 && $1+0==g+0 {found=1; exit} END {exit !found}'
}

tree_rss_kb() {
  local root=$1
  local total=0
  local pids
  pids=$(tree_pids "$root")
  for pid in $pids; do
    if [ -d "/proc/$pid" ] 2>/dev/null; then
      local rss
      rss=$(grep -E '^VmRSS:' /proc/$pid/status 2>/dev/null | awk '{print $2}')
      [ -n "$rss" ] && total=$((total + rss))
    fi
  done
  echo $total
}

# 优先 PGID，为 0 时回退树遍历
combined_rss_kb() {
  local root=$1
  local rss
  rss=$(pgid_rss_kb "$root")
  [ -z "$rss" ] && rss=0
  if [ "$rss" -eq 0 ]; then
    rss=$(tree_rss_kb "$root")
  fi
  [ -z "$rss" ] && rss=0
  echo $rss
}

PEAK_KB=0
START=$(date +%s)
echo "timestamp,tree_rss_kb" > "$OUTFILE"

while kill -0 "$ROOT_PID" 2>/dev/null; do
  rss=$(combined_rss_kb "$ROOT_PID")
  [ -z "$rss" ] && rss=0
  [ "$rss" -gt "$PEAK_KB" ] && PEAK_KB=$rss
  echo "$(date +%s.%N),$rss" >> "$OUTFILE"
  sleep $INTERVAL
done

END=$(date +%s)
RUNTIME=$((END - START))
# RSS in /proc/pid/status is in KB
PEAK_GB=$(echo "scale=4; $PEAK_KB / 1024 / 1024" | bc -l 2>/dev/null | sed 's/^\./0./')
[ -z "$PEAK_GB" ] && PEAK_GB=0

PEAK_FILE="${OUTFILE}.peaks"
echo "PEAK_RAM_KB=$PEAK_KB" > "$PEAK_FILE"
echo "PEAK_RAM_GB=$PEAK_GB" >> "$PEAK_FILE"
echo "RUNTIME_SECONDS=$RUNTIME" >> "$PEAK_FILE"
