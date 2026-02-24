#!/bin/bash
# 测量 serde-rs/serde 最小硬件：真实执行 build + test，进程树峰值监控（覆盖多线程/多进程）
set -euo pipefail

REPO_NAME="serde-rs_serde"
REPO_URL="https://github.com/serde-rs/serde"
WORK_DIR="/home/cc/Label/${REPO_NAME}_measure"
RESULT_DIR="/home/cc/Label/result"
MONITOR="/home/cc/Label/monitor_tree.sh"
LOG_FILE="${RESULT_DIR}/${REPO_NAME}_measure.log"

mkdir -p "$RESULT_DIR"
[ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"

cleanup() {
  # 保留最终 json 与日志，清理工作目录与监控中间文件
  rm -rf "$WORK_DIR"
  rm -f "$RESULT_DIR/serde_build" "$RESULT_DIR/serde_build.peaks" \
        "$RESULT_DIR/serde_run" "$RESULT_DIR/serde_run.peaks"
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

echo "=== [1/5] Clone 仓库 ===" | tee "$LOG_FILE"
rm -rf "$WORK_DIR"
git clone --depth 1 "$REPO_URL" "$WORK_DIR" 2>&1 | tee -a "$LOG_FILE"
cd "$WORK_DIR"

echo "=== [2/5] Build 阶段：cargo build -p serde --features derive --tests --jobs 1 ===" | tee -a "$LOG_FILE"
BUILD_START=$(date +%s)
set +e
cargo build -p serde --features derive --tests --jobs 1 2>&1 &
BUILD_PID=$!
BUILD_PGID=$(ps -o pgid= -p "$BUILD_PID" 2>/dev/null | tr -d ' ')
"$MONITOR" "$BUILD_PID" "$RESULT_DIR/serde_build" "$BUILD_PGID" &
MON1_PID=$!
wait "$BUILD_PID"
BUILD_EXIT=$?
wait "$MON1_PID" 2>/dev/null || true
set -e
BUILD_END=$(date +%s)
BUILD_RUNTIME=$((BUILD_END - BUILD_START))
if [ "$BUILD_EXIT" -ne 0 ]; then
  echo "Build 失败，exit=$BUILD_EXIT" | tee -a "$LOG_FILE"
  exit 1
fi

echo "=== [3/5] Run 阶段：cargo test -p serde --features derive --jobs 1 -- --test-threads=1 ===" | tee -a "$LOG_FILE"
RUN_START=$(date +%s)
set +e
cargo test -p serde --features derive --jobs 1 -- --test-threads=1 2>&1 &
RUN_PID=$!
RUN_PGID=$(ps -o pgid= -p "$RUN_PID" 2>/dev/null | tr -d ' ')
"$MONITOR" "$RUN_PID" "$RESULT_DIR/serde_run" "$RUN_PGID" &
MON2_PID=$!
wait "$RUN_PID"
RUN_EXIT=$?
wait "$MON2_PID" 2>/dev/null || true
set -e
RUN_END=$(date +%s)
RUN_RUNTIME=$((RUN_END - RUN_START))
if [ "$RUN_EXIT" -ne 0 ]; then
  echo "Run 失败，exit=$RUN_EXIT" | tee -a "$LOG_FILE"
  exit 2
fi

echo "=== [4/5] 汇总峰值 ===" | tee -a "$LOG_FILE"
BUILD_PEAK_GB=$(awk -F= '/^PEAK_RAM_GB=/{print $2}' "$RESULT_DIR/serde_build.peaks" | tr -d '[:space:]')
RUN_PEAK_GB=$(awk -F= '/^PEAK_RAM_GB=/{print $2}' "$RESULT_DIR/serde_run.peaks" | tr -d '[:space:]')
[ -z "$BUILD_PEAK_GB" ] && BUILD_PEAK_GB=0
[ -z "$RUN_PEAK_GB" ] && RUN_PEAK_GB=0

DISK_KB=$(du -sk "$WORK_DIR" | awk '{print $1}')
DISK_GB=$(awk -v kb="$DISK_KB" 'BEGIN{printf "%.4f", kb/1024/1024}')
[ -z "$DISK_GB" ] && DISK_GB=0

MIN_BUILD_RAM=$(round_ram "$BUILD_PEAK_GB")
MIN_RUN_RAM=$(round_ram "$RUN_PEAK_GB")
MIN_RAM=$MIN_BUILD_RAM
[ "$MIN_RUN_RAM" -gt "$MIN_RAM" ] && MIN_RAM=$MIN_RUN_RAM
MIN_DISK=$(round_disk "$DISK_GB")

echo "=== [5/5] 输出 JSON ===" | tee -a "$LOG_FILE"
cat > "$RESULT_DIR/${REPO_NAME}.json" << EOF
{
  "name": "${REPO_NAME}",
  "url": "${REPO_URL}",
  "mvw": {
    "mvw_command": "cargo build -p serde --features derive --tests --jobs 1 && cargo test -p serde --features derive --jobs 1 -- --test-threads=1",
    "build_command": "cargo build -p serde --features derive --tests --jobs 1",
    "run_command": "cargo test -p serde --features derive --jobs 1 -- --test-threads=1",
    "input_scale": "serde crate with derive feature, single-job build and single-thread test",
    "success_criteria": "both commands exit code 0"
  },
  "environment": {
    "os": "Linux",
    "rust_toolchain": "$(rustc --version)",
    "methodology": "tutorial.md one-pass profiling; process-tree RSS peak (monitor_tree.sh), whole tree not single process; MVW actually run; multi-thread/multi-process peak included."
  },
  "static_triage": {
    "requires_gpu": false,
    "likely_bottlenecks": ["RAM", "CPU", "Disk"],
    "notes": "Rust serialization framework; no GPU requirement; build/test are CPU and memory sensitive."
  },
  "peaks_observed": {
    "build_peak_ram_gb": ${BUILD_PEAK_GB},
    "run_peak_ram_gb": ${RUN_PEAK_GB},
    "peak_disk_gb": ${DISK_GB},
    "build_runtime_seconds": ${BUILD_RUNTIME},
    "run_runtime_seconds": ${RUN_RUNTIME},
    "cpu_utilization_summary": "build moderate-high (cargo compiling crates), run moderate (unit and integration tests)"
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
    "summary": "2 vCPU / ${MIN_RAM} GB RAM / ${MIN_DISK} GB disk, no GPU. Raw process-tree peaks: build ${BUILD_PEAK_GB} GB, run ${RUN_PEAK_GB} GB, disk ${DISK_GB} GB."
  }
}
EOF

echo "测量完成：$RESULT_DIR/${REPO_NAME}.json" | tee -a "$LOG_FILE"
echo "BUILD_PEAK_GB=${BUILD_PEAK_GB}" | tee -a "$LOG_FILE"
echo "RUN_PEAK_GB=${RUN_PEAK_GB}" | tee -a "$LOG_FILE"
echo "DISK_GB=${DISK_GB}" | tee -a "$LOG_FILE"
echo "BUILD_RUNTIME_S=${BUILD_RUNTIME}" | tee -a "$LOG_FILE"
echo "RUN_RUNTIME_S=${RUN_RUNTIME}" | tee -a "$LOG_FILE"
