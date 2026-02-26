#!/bin/bash
# Measure minimal hardware for alibaba/fastjson2: real execution of Maven build + test,
# with process-tree peak RSS monitoring (covers multi-process JVM workers spawned by Maven).
# Requires: git, java (JDK 8+), internet access (Maven downloads dependencies)
set -euo pipefail

REPO_NAME="alibaba_fastjson2"
REPO_URL="https://github.com/alibaba/fastjson2"
WORK_DIR="/home/cc/Label/${REPO_NAME}_measure"
RESULT_DIR="/home/cc/Label/result"
MONITOR="/home/cc/Label/monitor_tree.sh"
LOG_FILE="${RESULT_DIR}/${REPO_NAME}_measure.log"

BUILD_CSV="${RESULT_DIR}/${REPO_NAME}_build"
RUN_CSV="${RESULT_DIR}/${REPO_NAME}_run"

# MVW definition:
#   Build: compile the core module (the primary JSON parser/generator) plus its reactor deps
#   Run:   run tests of the core module
BUILD_CMD="./mvnw -V --no-transfer-progress -pl core -am compile test-compile -DskipTests"
RUN_CMD="./mvnw -V --no-transfer-progress -pl core test"

mkdir -p "$RESULT_DIR"

cleanup() {
  echo "=== cleanup ===" | tee -a "$LOG_FILE"
  rm -rf "$WORK_DIR"
  rm -f "$BUILD_CSV" "$BUILD_CSV.peaks" "$RUN_CSV" "$RUN_CSV.peaks"
  # Keep result/<REPO_NAME>.json and log
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Helper: round up to common SKU sizes
# ---------------------------------------------------------------------------
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

# ===========================================================================
echo "=== [1/6] Clone repository ===" | tee "$LOG_FILE"
# ===========================================================================
rm -rf "$WORK_DIR"
git clone --depth 1 "$REPO_URL" "$WORK_DIR" 2>&1 | tee -a "$LOG_FILE"
cd "$WORK_DIR"

# Make the Maven wrapper executable
chmod +x mvnw

# ===========================================================================
echo "=== [2/6] Static triage ===" | tee -a "$LOG_FILE"
# ===========================================================================
# fastjson2 is a pure Java JSON library. No GPU dependency.
# Main bottlenecks: RAM (Maven + javac + JVM workers), Disk (Maven deps cache),
# CPU (parallel compilation and test execution).
REQUIRES_GPU=false
echo "requires_gpu=$REQUIRES_GPU" | tee -a "$LOG_FILE"

# ===========================================================================
echo "=== [3/6] Build phase: mvnw compile test-compile (core module) ===" | tee -a "$LOG_FILE"
# ===========================================================================
BUILD_START=$(date +%s)
(
  set -e
  cd "$WORK_DIR"
  $BUILD_CMD 2>&1
) 2>&1 | tee -a "$LOG_FILE" &
BUILD_PID=$!
sleep 0.5
BUILD_PGID=$(ps -o pgid= -p "$BUILD_PID" 2>/dev/null | tr -d ' ')
"$MONITOR" "$BUILD_PID" "$BUILD_CSV" "$BUILD_PGID" &
MON_BUILD_PID=$!
wait "$BUILD_PID"
BUILD_EXIT=$?
wait "$MON_BUILD_PID" 2>/dev/null || true
BUILD_END=$(date +%s)
BUILD_RUNTIME=$((BUILD_END - BUILD_START))

if [ "$BUILD_EXIT" -ne 0 ]; then
  echo "Build phase failed with exit=$BUILD_EXIT" | tee -a "$LOG_FILE"
  exit 1
fi

echo "Build succeeded in ${BUILD_RUNTIME}s" | tee -a "$LOG_FILE"

# ===========================================================================
echo "=== [4/6] Run phase: mvnw test (core module) ===" | tee -a "$LOG_FILE"
# ===========================================================================
RUN_START=$(date +%s)
(
  set -e
  cd "$WORK_DIR"
  $RUN_CMD 2>&1
) 2>&1 | tee -a "$LOG_FILE" &
RUN_PID=$!
sleep 0.5
RUN_PGID=$(ps -o pgid= -p "$RUN_PID" 2>/dev/null | tr -d ' ')
"$MONITOR" "$RUN_PID" "$RUN_CSV" "$RUN_PGID" &
MON_RUN_PID=$!
wait "$RUN_PID"
RUN_EXIT=$?
wait "$MON_RUN_PID" 2>/dev/null || true
RUN_END=$(date +%s)
RUN_RUNTIME=$((RUN_END - RUN_START))

if [ "$RUN_EXIT" -ne 0 ]; then
  echo "Run phase failed with exit=$RUN_EXIT" | tee -a "$LOG_FILE"
  exit 2
fi

echo "Test succeeded in ${RUN_RUNTIME}s" | tee -a "$LOG_FILE"

# ===========================================================================
echo "=== [5/6] Collect peaks ===" | tee -a "$LOG_FILE"
# ===========================================================================
build_peak_gb=$(awk -F= '/^PEAK_RAM_GB=/{print $2}' "$BUILD_CSV.peaks" | tr -d '[:space:]')
run_peak_gb=$(awk -F= '/^PEAK_RAM_GB=/{print $2}' "$RUN_CSV.peaks" | tr -d '[:space:]')

[ -z "${build_peak_gb:-}" ] && build_peak_gb=0
[ -z "${run_peak_gb:-}" ] && run_peak_gb=0

# Fallback: parse CSV directly if .peaks file reported 0
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

min_build_ram=$(round_ram "$build_peak_gb")
min_run_ram=$(round_ram "$run_peak_gb")
min_disk=$(round_disk "$disk_gb")
min_ram="$min_build_ram"
[ "$min_run_ram" -gt "$min_ram" ] && min_ram="$min_run_ram"

# ===========================================================================
echo "=== [6/6] Write result JSON ===" | tee -a "$LOG_FILE"
# ===========================================================================
cat > "$RESULT_DIR/${REPO_NAME}.json" <<EOF
{
  "name": "${REPO_NAME}",
  "url": "${REPO_URL}",
  "mvw": {
    "mvw_command": "./mvnw -V --no-transfer-progress -pl core -am clean package",
    "build_command": "./mvnw -V --no-transfer-progress -pl core -am compile test-compile -DskipTests",
    "run_command": "./mvnw -V --no-transfer-progress -pl core test",
    "input_scale": "core module only (the primary JSON parser/generator); default Maven test configuration",
    "success_criteria": "both mvnw commands exit code 0, Maven reports BUILD SUCCESS"
  },
  "environment": {
    "os": "Linux",
    "java": "$(java -version 2>&1 | head -1 || echo unknown)",
    "maven_wrapper": "3.9.9 (via .mvn/wrapper/maven-wrapper.properties)",
    "methodology": "tutorial.md one-pass profiling; process-tree RSS peak via monitor_tree.sh (captures multi-process JVM workers spawned by Maven); build/run split; real execution."
  },
  "static_triage": {
    "requires_gpu": false,
    "likely_bottlenecks": ["RAM", "CPU", "Disk"],
    "notes": "Pure Java JSON library (alibaba/fastjson2). Multi-module Maven project; core module is the primary artifact. Maven spawns forked JVM processes for surefire tests. No GPU dependency. Java 8+ compatible. Dependencies downloaded on first run."
  },
  "peaks_observed": {
    "build_peak_ram_gb": ${build_peak_gb},
    "run_peak_ram_gb": ${run_peak_gb},
    "peak_disk_gb": ${disk_gb},
    "build_runtime_seconds": ${BUILD_RUNTIME},
    "run_runtime_seconds": ${RUN_RUNTIME},
    "cpu_utilization_summary": "build: Maven compilation (javac, multi-module reactor); run: JUnit 5 tests via Maven surefire (forked JVM)"
  },
  "margins_used": "none",
  "min_hardware": {
    "build_min_spec": {"min_ram_gb": ${min_build_ram}, "min_disk_gb": ${min_disk}, "min_vcpu": 2},
    "run_min_spec": {"min_ram_gb": ${min_run_ram}, "min_disk_gb": ${min_disk}, "min_vcpu": 2},
    "summary": "2 vCPU / ${min_ram} GB RAM / ${min_disk} GB disk, no GPU. Raw process-tree peaks: build ${build_peak_gb} GB, run ${run_peak_gb} GB, disk ${disk_gb} GB."
  }
}
EOF

echo "Done: $RESULT_DIR/${REPO_NAME}.json" | tee -a "$LOG_FILE"
echo "BUILD_PEAK_GB=${build_peak_gb}" | tee -a "$LOG_FILE"
echo "RUN_PEAK_GB=${run_peak_gb}" | tee -a "$LOG_FILE"
echo "DISK_GB=${disk_gb}" | tee -a "$LOG_FILE"
echo "BUILD_RUNTIME_S=${BUILD_RUNTIME}" | tee -a "$LOG_FILE"
echo "RUN_RUNTIME_S=${RUN_RUNTIME}" | tee -a "$LOG_FILE"
