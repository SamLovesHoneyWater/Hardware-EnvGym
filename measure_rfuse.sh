#!/bin/bash
# Measure minimal hardware for snu-csl/rfuse with real execution.
set -euo pipefail

REPO_URL="https://github.com/snu-csl/rfuse"
WORK_ROOT="/home/cc/Label/rfuse_measure"
WORK_DIR="$WORK_ROOT/rfuse"
RESULT_DIR="/home/cc/Label/result"
MONITOR="/home/cc/Label/monitor_tree.sh"
LOG_FILE="$RESULT_DIR/rfuse_measure.log"

BUILD_CSV="$RESULT_DIR/rfuse_build"
RUN_CSV="$RESULT_DIR/rfuse_run"

mkdir -p "$RESULT_DIR" "$WORK_ROOT"
export PATH="$HOME/.local/bin:$PATH"

cleanup() {
  echo "=== cleanup ===" | tee -a "$LOG_FILE"
  # Ensure no mount process remains (best effort)
  pkill -f "/home/cc/Label/rfuse_measure/rfuse/lib/librfuse/build/example/" 2>/dev/null || true
  # Remove working tree and temporary monitor files
  rm -rf "$WORK_DIR"
  rm -f "$BUILD_CSV" "$BUILD_CSV.peaks" "$RUN_CSV" "$RUN_CSV.peaks"
}
trap cleanup EXIT

echo "=== [1/5] clone rfuse ===" | tee "$LOG_FILE"
rm -rf "$WORK_DIR"
git clone --depth 1 "$REPO_URL" "$WORK_DIR" 2>&1 | tee -a "$LOG_FILE"

echo "=== [2/5] static triage ===" | tee -a "$LOG_FILE"
REQUIRES_GPU=false
if rg -i "cuda|rocm|nvidia|tensorflow-gpu|--gpus" "$WORK_DIR" >/dev/null 2>&1; then
  REQUIRES_GPU=true
fi
echo "requires_gpu=$REQUIRES_GPU" | tee -a "$LOG_FILE"

echo "=== [3/5] build phase: meson+ninja ===" | tee -a "$LOG_FILE"
BUILD_START=$(date +%s)
(
  set -e
  cd "$WORK_DIR/lib/librfuse"
  rm -rf build
  meson setup build -Dutils=false -Dtests=true
  ninja -C build -j"$(nproc)"
) &
BUILD_PID=$!
sleep 0.1
"$MONITOR" "$BUILD_PID" "$BUILD_CSV" &
MON_BUILD_PID=$!
wait "$BUILD_PID"
wait "$MON_BUILD_PID" || true
BUILD_END=$(date +%s)
BUILD_RUNTIME=$((BUILD_END - BUILD_START))

echo "=== [4/5] run phase: pytest test/ ===" | tee -a "$LOG_FILE"
RUN_START=$(date +%s)
(
  set -e
  cd "$WORK_DIR/lib/librfuse/build"
  python3 -m pytest -q ../test
) 2>&1 | tee -a "$LOG_FILE" &
RUN_PID=$!
sleep 0.1
"$MONITOR" "$RUN_PID" "$RUN_CSV" &
MON_RUN_PID=$!
wait "$RUN_PID"
RUN_EXIT=$?
wait "$MON_RUN_PID" || true
RUN_END=$(date +%s)
RUN_RUNTIME=$((RUN_END - RUN_START))

if [ "$RUN_EXIT" -ne 0 ]; then
  echo "run phase failed with exit=$RUN_EXIT" | tee -a "$LOG_FILE"
  exit 1
fi

build_peak_gb=$(awk -F= '/^PEAK_RAM_GB=/{print $2}' "$BUILD_CSV.peaks")
run_peak_gb=$(awk -F= '/^PEAK_RAM_GB=/{print $2}' "$RUN_CSV.peaks")

if [ -z "${build_peak_gb:-}" ]; then build_peak_gb=0; fi
if [ -z "${run_peak_gb:-}" ]; then run_peak_gb=0; fi

# Fallback: if .peaks is zero because process finished quickly, read max from csv samples.
build_max_kb=$(awk -F, 'NR>1 && $2+0>m {m=$2+0} END {print m+0}' "$BUILD_CSV" 2>/dev/null || echo 0)
run_max_kb=$(awk -F, 'NR>1 && $2+0>m {m=$2+0} END {print m+0}' "$RUN_CSV" 2>/dev/null || echo 0)
if awk -v v="$build_peak_gb" 'BEGIN{exit !(v==0)}'; then
  build_peak_gb=$(awk -v kb="$build_max_kb" 'BEGIN{printf "%.4f", kb/1024/1024}')
fi
if awk -v v="$run_peak_gb" 'BEGIN{exit !(v==0)}'; then
  run_peak_gb=$(awk -v kb="$run_max_kb" 'BEGIN{printf "%.4f", kb/1024/1024}')
fi

DISK_KB=$(du -sk "$WORK_DIR" | awk '{print $1}')
disk_gb=$(awk -v kb="$DISK_KB" 'BEGIN{printf "%.4f", kb/1024/1024}')

round_ram() {
  local v="$1"
  awk -v x="$v" 'BEGIN{
    if (x <= 2) print 2;
    else if (x <= 4) print 4;
    else if (x <= 8) print 8;
    else if (x <= 16) print 16;
    else if (x <= 32) print 32;
    else print int(x+7)/8*8;
  }'
}

round_disk() {
  local v="$1"
  awk -v x="$v" 'BEGIN{
    if (x <= 1) print 1;
    else if (x <= 2) print 2;
    else if (x <= 4) print 4;
    else if (x <= 8) print 8;
    else if (x <= 16) print 16;
    else print int(x+7)/8*8;
  }'
}

min_build_ram=$(round_ram "$build_peak_gb")
min_run_ram=$(round_ram "$run_peak_gb")
min_disk=$(round_disk "$disk_gb")
min_ram="$min_build_ram"
if [ "$min_run_ram" -gt "$min_ram" ]; then
  min_ram="$min_run_ram"
fi

echo "=== [5/5] write result/rfuse.json ===" | tee -a "$LOG_FILE"
cat > "$RESULT_DIR/rfuse.json" <<EOF
{
  "name": "rfuse",
  "url": "https://github.com/snu-csl/rfuse",
  "mvw": {
    "mvw_command": "cd lib/librfuse && meson setup build -Dutils=false -Dtests=true && ninja -C build -j\$(nproc) && cd build && python3 -m pytest -q ../test",
    "build_command": "cd lib/librfuse && meson setup build -Dutils=false -Dtests=true && ninja -C build -j\$(nproc)",
    "run_command": "cd lib/librfuse/build && python3 -m pytest -q ../test",
    "input_scale": "Full librfuse library+tests build (utils disabled due missing udev in this host) and full pytest test directory execution",
    "success_criteria": "build exits 0; pytest exits 0 (pass/skip allowed); command truly executed with process-tree monitoring"
  },
  "environment": {
    "os": "Linux",
    "methodology": "tutorial.md one-pass profiling; process-tree RSS peak via monitor_tree.sh; build/run split; real execution (not static analysis)."
  },
  "static_triage": {
    "requires_gpu": $REQUIRES_GPU,
    "likely_bottlenecks": ["RAM", "CPU", "Disk"],
    "notes": "Kernel driver install/mount workflow needs sudo/reboot in project README. Host misses udev dev package, so MVW uses librfuse build with -Dutils=false to avoid system-level install dependency."
  },
  "peaks_observed": {
    "build_peak_ram_gb": $build_peak_gb,
    "run_peak_ram_gb": $run_peak_gb,
    "peak_disk_gb": $disk_gb,
    "build_runtime_seconds": $BUILD_RUNTIME,
    "run_runtime_seconds": $RUN_RUNTIME,
    "cpu_utilization_summary": "build: parallel compilation with ninja; run: pytest executes librfuse test suite (many mount tests may skip based on host privilege/device capabilities)"
  },
  "margins_used": "none",
  "min_hardware": {
    "build_min_spec": {"min_ram_gb": $min_build_ram, "min_disk_gb": $min_disk, "min_vcpu": 2},
    "run_min_spec": {"min_ram_gb": $min_run_ram, "min_disk_gb": $min_disk, "min_vcpu": 2},
    "summary": "2 vCPU / $min_ram GB RAM / $min_disk GB disk, no GPU. Raw process-tree peaks: build ${build_peak_gb} GB, run ${run_peak_gb} GB, disk ${disk_gb} GB."
  }
}
EOF

echo "Done: $RESULT_DIR/rfuse.json" | tee -a "$LOG_FILE"
