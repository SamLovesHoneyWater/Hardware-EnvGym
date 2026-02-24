#!/bin/bash
# 测量 zeromicro/go-zero 最小硬件：真实执行 build + test，统计进程组峰值资源
set -euo pipefail

REPO_NAME="zeromicro_go-zero"
REPO_URL="https://github.com/zeromicro/go-zero"
WORK_DIR="/home/cc/Label/${REPO_NAME}_measure"
RESULT_DIR="/home/cc/Label/result"
LOG_FILE="${RESULT_DIR}/${REPO_NAME}_measure.log"
GO_BIN="/home/cc/.local/go-install/go/bin/go"
MONITOR_TREE="/home/cc/Label/monitor_tree.sh"

BUILD_CMD="go build ./..."
RUN_CMD="go test -short ./core/..."

mkdir -p "$RESULT_DIR"

cleanup() {
  chmod -R u+w "$WORK_DIR" 2>/dev/null || true
  rm -rf "$WORK_DIR" 2>/dev/null || true
  rm -f "$RESULT_DIR/${REPO_NAME}_build.ram" "$RESULT_DIR/${REPO_NAME}_build.ram.peaks"
  rm -f "$RESULT_DIR/${REPO_NAME}_run.ram" "$RESULT_DIR/${REPO_NAME}_run.ram.peaks"
  rm -f "$RESULT_DIR/${REPO_NAME}_build.aux" "$RESULT_DIR/${REPO_NAME}_build.aux.peaks"
  rm -f "$RESULT_DIR/${REPO_NAME}_run.aux" "$RESULT_DIR/${REPO_NAME}_run.aux.peaks"
}
trap cleanup EXIT

round_ram() {
  local v=$1
  local i
  i=$(echo "$v" | awk '{print int($1)}')
  if [ "$i" -lt 1 ]; then echo 2
  elif [ "$i" -lt 2 ]; then echo 2
  elif [ "$i" -lt 4 ]; then echo 4
  elif [ "$i" -lt 8 ]; then echo 8
  elif [ "$i" -lt 16 ]; then echo 16
  else echo $(( (i/8 + 1) * 8 )); fi
}

round_disk() {
  local v=$1
  local i
  i=$(echo "$v" | awk '{print int($1)}')
  if [ "$i" -lt 1 ]; then echo 1
  elif [ "$i" -lt 2 ]; then echo 2
  elif [ "$i" -lt 4 ]; then echo 4
  elif [ "$i" -lt 8 ]; then echo 8
  else echo $(( (i/8 + 1) * 8 )); fi
}

monitor_aux() {
  local root_pid=$1
  local out_file=$2
  local root_pgid=$3
  local repo_dir=$4
  local gomodcache=$5
  local gocache=$6
  local interval=0.5

  local peak_disk_kb=0
  local peak_cpu_pct=0
  local peak_threads=0
  local start_ts end_ts runtime

  start_ts=$(date +%s)
  echo "timestamp,total_cpu_percent,total_threads,disk_kb" > "$out_file"

  while kill -0 "$root_pid" 2>/dev/null; do
    local cpu_pct threads disk_kb current_pgid pids

    current_pgid="$root_pgid"
    if [ -z "$current_pgid" ]; then
      current_pgid=$(ps -o pgid= -p "$root_pid" 2>/dev/null | tr -d ' ')
    fi

    cpu_pct=$(ps -eo pgid=,pcpu= 2>/dev/null | awk -v g="$current_pgid" '$1+0==g+0 {s+=$2} END{printf "%.2f", s+0}')
    threads=$(ps -eo pgid=,nlwp= 2>/dev/null | awk -v g="$current_pgid" '$1+0==g+0 {s+=$2} END{print s+0}')
    if [ "$threads" -eq 0 ]; then
      pids=$(ps -eo ppid=,pid= 2>/dev/null | awk -v p="$root_pid" '$1+0==p+0 {print $2}')
      pids="$root_pid $pids"
      cpu_pct=$(ps -eo pid=,pcpu= 2>/dev/null | awk -v list="$pids" 'BEGIN{split(list,a); for(i in a) keep[a[i]]=1} {if(keep[$1]) s+=$2} END{printf "%.2f", s+0}')
      threads=$(ps -eo pid=,nlwp= 2>/dev/null | awk -v list="$pids" 'BEGIN{split(list,a); for(i in a) keep[a[i]]=1} {if(keep[$1]) s+=$2} END{print s+0}')
    fi
    disk_kb=$(du -sk "$repo_dir" "$gomodcache" "$gocache" 2>/dev/null | awk '{s+=$1} END{print s+0}')

    awk -v a="$cpu_pct" -v b="$peak_cpu_pct" 'BEGIN{exit !(a>b)}' && peak_cpu_pct="$cpu_pct"
    [ "$threads" -gt "$peak_threads" ] && peak_threads="$threads"
    [ "$disk_kb" -gt "$peak_disk_kb" ] && peak_disk_kb="$disk_kb"

    echo "$(date +%s.%N),$cpu_pct,$threads,$disk_kb" >> "$out_file"
    sleep "$interval"
  done

  end_ts=$(date +%s)
  runtime=$((end_ts - start_ts))

  cat > "${out_file}.peaks" << EOF
PEAK_CPU_PERCENT=$peak_cpu_pct
PEAK_THREADS=$peak_threads
PEAK_DISK_KB=$peak_disk_kb
PEAK_DISK_GB=$(awk -v kb="$peak_disk_kb" 'BEGIN{printf "%.4f", kb/1024/1024}')
RUNTIME_SECONDS=$runtime
EOF
}

run_phase() {
  local phase_name=$1
  local phase_cmd=$2
  local monitor_ram="$RESULT_DIR/${REPO_NAME}_${phase_name}.ram"
  local monitor_aux_file="$RESULT_DIR/${REPO_NAME}_${phase_name}.aux"
  local start_ts end_ts runtime exit_code phase_pid phase_pgid mon_ram_pid mon_aux_pid

  start_ts=$(date +%s)
  set +e
  (
    cd "$WORK_DIR"
    export PATH="/home/cc/.local/go-install/go/bin:$PATH"
    export GOTOOLCHAIN=local
    export GOMODCACHE="$WORK_DIR/.gocache/mod"
    export GOCACHE="$WORK_DIR/.gocache/build"
    bash -lc "$phase_cmd"
  ) >> "$LOG_FILE" 2>&1 &
  phase_pid=$!
  phase_pgid=$(ps -o pgid= -p "$phase_pid" 2>/dev/null | tr -d ' ')
  "$MONITOR_TREE" "$phase_pid" "$monitor_ram" "$phase_pgid" &
  mon_ram_pid=$!
  monitor_aux "$phase_pid" "$monitor_aux_file" "$phase_pgid" "$WORK_DIR" "$WORK_DIR/.gocache/mod" "$WORK_DIR/.gocache/build" &
  mon_aux_pid=$!
  wait "$phase_pid"
  exit_code=$?
  wait "$mon_ram_pid" 2>/dev/null || true
  wait "$mon_aux_pid" 2>/dev/null || true
  set -e
  end_ts=$(date +%s)
  runtime=$((end_ts - start_ts))

  if [ "$exit_code" -ne 0 ]; then
    echo "${phase_name} 阶段失败，exit=$exit_code" | tee -a "$LOG_FILE"
    exit 2
  fi

  echo "$runtime"
}

echo "=== [1/5] 环境检查 ===" | tee "$LOG_FILE"
if [ ! -x "$GO_BIN" ]; then
  echo "未找到 Go 工具链: $GO_BIN" | tee -a "$LOG_FILE"
  exit 1
fi

echo "=== [2/5] Clone 仓库 ===" | tee -a "$LOG_FILE"
rm -rf "$WORK_DIR"
git clone --depth 1 "$REPO_URL" "$WORK_DIR" >> "$LOG_FILE" 2>&1
mkdir -p "$WORK_DIR/.gocache/mod" "$WORK_DIR/.gocache/build"

echo "=== [3/5] Build 阶段: $BUILD_CMD ===" | tee -a "$LOG_FILE"
BUILD_RUNTIME=$(run_phase "build" "$BUILD_CMD")

echo "=== [4/5] Run 阶段: $RUN_CMD ===" | tee -a "$LOG_FILE"
RUN_RUNTIME=$(run_phase "run" "$RUN_CMD")

echo "=== [5/5] 汇总并写入 JSON ===" | tee -a "$LOG_FILE"
BUILD_PEAK_RAM_GB=$(awk -F= '/^PEAK_RAM_GB=/{print $2}' "$RESULT_DIR/${REPO_NAME}_build.ram.peaks")
RUN_PEAK_RAM_GB=$(awk -F= '/^PEAK_RAM_GB=/{print $2}' "$RESULT_DIR/${REPO_NAME}_run.ram.peaks")
BUILD_PEAK_CPU=$(awk -F= '/^PEAK_CPU_PERCENT=/{print $2}' "$RESULT_DIR/${REPO_NAME}_build.aux.peaks")
RUN_PEAK_CPU=$(awk -F= '/^PEAK_CPU_PERCENT=/{print $2}' "$RESULT_DIR/${REPO_NAME}_run.aux.peaks")
BUILD_PEAK_THREADS=$(awk -F= '/^PEAK_THREADS=/{print $2}' "$RESULT_DIR/${REPO_NAME}_build.aux.peaks")
RUN_PEAK_THREADS=$(awk -F= '/^PEAK_THREADS=/{print $2}' "$RESULT_DIR/${REPO_NAME}_run.aux.peaks")
BUILD_PEAK_DISK_GB=$(awk -F= '/^PEAK_DISK_GB=/{print $2}' "$RESULT_DIR/${REPO_NAME}_build.aux.peaks")
RUN_PEAK_DISK_GB=$(awk -F= '/^PEAK_DISK_GB=/{print $2}' "$RESULT_DIR/${REPO_NAME}_run.aux.peaks")

MAX_RAM_GB=$(awk -v a="$BUILD_PEAK_RAM_GB" -v b="$RUN_PEAK_RAM_GB" 'BEGIN{if(a>b) printf "%.4f",a; else printf "%.4f",b}')
MAX_DISK_GB=$(awk -v a="$BUILD_PEAK_DISK_GB" -v b="$RUN_PEAK_DISK_GB" 'BEGIN{if(a>b) printf "%.4f",a; else printf "%.4f",b}')
MIN_BUILD_RAM=$(round_ram "$BUILD_PEAK_RAM_GB")
MIN_RUN_RAM=$(round_ram "$RUN_PEAK_RAM_GB")
MIN_RAM=$(round_ram "$MAX_RAM_GB")
MIN_DISK=$(round_disk "$MAX_DISK_GB")

cat > "$RESULT_DIR/${REPO_NAME}.json" << EOF
{
  "name": "${REPO_NAME}",
  "url": "${REPO_URL}",
  "mvw": {
    "mvw_command": "go build ./... && go test -short ./core/...",
    "build_command": "${BUILD_CMD}",
    "run_command": "${RUN_CMD}",
    "input_scale": "full repository build plus short tests on core packages",
    "success_criteria": "both commands exit code 0"
  },
  "environment": {
    "os": "Linux",
    "go_version": "$("$GO_BIN" version)",
    "methodology": "tutorial.md one-pass profiling; process-group tree peak monitoring for RAM/CPU/threads and disk (repo + go build cache + module cache); workload actually executed."
  },
  "static_triage": {
    "requires_gpu": false,
    "likely_bottlenecks": ["RAM", "CPU", "Disk"],
    "notes": "Go microservice framework; no GPU dependency found; build and tests are parallelized by Go toolchain."
  },
  "peaks_observed": {
    "build_peak_ram_gb": ${BUILD_PEAK_RAM_GB},
    "run_peak_ram_gb": ${RUN_PEAK_RAM_GB},
    "peak_disk_gb": ${MAX_DISK_GB},
    "build_runtime_seconds": ${BUILD_RUNTIME},
    "run_runtime_seconds": ${RUN_RUNTIME},
    "cpu_utilization_summary": "build peak ${BUILD_PEAK_CPU}% (threads peak ${BUILD_PEAK_THREADS}), run peak ${RUN_PEAK_CPU}% (threads peak ${RUN_PEAK_THREADS})"
  },
  "margins_used": "none",
  "min_hardware": {
    "build_min_spec": {
      "min_ram_gb": ${MIN_BUILD_RAM},
      "min_disk_gb": ${MIN_DISK},
      "min_vcpu": 2
    },
    "run_min_spec": {
      "min_ram_gb": ${MIN_RUN_RAM},
      "min_disk_gb": ${MIN_DISK},
      "min_vcpu": 2
    },
    "summary": "2 vCPU / ${MIN_RAM} GB RAM / ${MIN_DISK} GB disk, no GPU. Raw peaks: build RAM ${BUILD_PEAK_RAM_GB} GB, run RAM ${RUN_PEAK_RAM_GB} GB, disk ${MAX_DISK_GB} GB."
  }
}
EOF

echo "测量完成: $RESULT_DIR/${REPO_NAME}.json" | tee -a "$LOG_FILE"
echo "已清理工作目录: $WORK_DIR（通过 EXIT trap）" | tee -a "$LOG_FILE"
