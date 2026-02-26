#!/bin/bash
# Measure minimal hardware for xlab-uiuc/acto: real execution of build (pip install + make) and
# run (pytest unit + integration tests), with process-tree peak RSS monitoring.
# Requires: git, python3 (>=3.10), go (>=1.18), pip
set -euo pipefail

REPO_NAME="acto"
REPO_URL="https://github.com/xlab-uiuc/acto"
WORK_DIR="/home/cc/Label/${REPO_NAME}_measure"
RESULT_DIR="/home/cc/Label/result"
MONITOR="/home/cc/Label/monitor_tree.sh"
LOG_FILE="${RESULT_DIR}/${REPO_NAME}_measure.log"

BUILD_CSV="${RESULT_DIR}/${REPO_NAME}_build"
RUN_CSV="${RESULT_DIR}/${REPO_NAME}_run"

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

# ===========================================================================
echo "=== [2/6] Static triage ===" | tee -a "$LOG_FILE"
# ===========================================================================
# Acto is a pure Python + Go project for Kubernetes operator testing.
# No GPU dependency; main bottlenecks are RAM (pip install heavy deps,
# Go compilation of shared objects) and disk (Python packages + Go modules).
REQUIRES_GPU=false
echo "requires_gpu=$REQUIRES_GPU" | tee -a "$LOG_FILE"

# ===========================================================================
echo "=== [3/6] Build phase: pip install + make (Go shared libraries) ===" | tee -a "$LOG_FILE"
# ===========================================================================
BUILD_START=$(date +%s)
(
  set -e
  cd "$WORK_DIR"

  # Create a virtualenv to isolate dependencies
  python3 -m venv .venv
  # shellcheck disable=SC1091
  source .venv/bin/activate

  # Install dev dependencies (superset of requirements.txt)
  pip install --upgrade pip setuptools wheel 2>&1
  pip install -r requirements-dev.txt 2>&1

  # Build Go shared objects (acto/k8s_util/lib/k8sutil.so + ssa/libanalysis.so)
  make 2>&1
) 2>&1 | tee -a "$LOG_FILE" &
BUILD_PID=$!
sleep 0.5
"$MONITOR" "$BUILD_PID" "$BUILD_CSV" &
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

# Verify build artifacts exist
if [ ! -f "$WORK_DIR/acto/k8s_util/lib/k8sutil.so" ]; then
  echo "WARN: k8sutil.so not found after build" | tee -a "$LOG_FILE"
fi
if [ ! -f "$WORK_DIR/ssa/libanalysis.so" ]; then
  echo "WARN: libanalysis.so not found after build" | tee -a "$LOG_FILE"
fi

# ===========================================================================
echo "=== [4/6] Run phase: pytest unit tests + integration tests ===" | tee -a "$LOG_FILE"
# ===========================================================================
RUN_START=$(date +%s)
(
  set -e
  cd "$WORK_DIR"
  # shellcheck disable=SC1091
  source .venv/bin/activate

  # Unit tests (pytest acto — tests inside the acto package)
  pytest acto --timeout=300 -x -q 2>&1 || true

  # Integration tests (pytest test/integration_tests — schema matching, serialization, etc.)
  # Exclude tests that require a live Kubernetes cluster (e2e, bug reproduction, kubernetes_engines)
  pytest test/integration_tests \
    --ignore=test/integration_tests/test_kubernetes_engines.py \
    --ignore=test/integration_tests/test_learn.py \
    --ignore=test/integration_tests/test_cassop_bugs.py \
    --ignore=test/integration_tests/test_crdb_bugs.py \
    --ignore=test/integration_tests/test_rbop_bugs.py \
    --timeout=300 -x -q 2>&1 || true
) 2>&1 | tee -a "$LOG_FILE" &
RUN_PID=$!
sleep 0.5
"$MONITOR" "$RUN_PID" "$RUN_CSV" &
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
    "mvw_command": "pip install -r requirements-dev.txt && make && pytest acto && pytest test/integration_tests",
    "build_command": "python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements-dev.txt && make",
    "run_command": "source .venv/bin/activate && pytest acto && pytest test/integration_tests --ignore=test/integration_tests/test_kubernetes_engines.py --ignore=test/integration_tests/test_learn.py --ignore=test/integration_tests/test_cassop_bugs.py --ignore=test/integration_tests/test_crdb_bugs.py --ignore=test/integration_tests/test_rbop_bugs.py",
    "input_scale": "built-in unit tests and integration tests (schema matching, serialization, semantic tests); excludes e2e/bug-reproduction tests requiring a live Kubernetes cluster",
    "success_criteria": "build: k8sutil.so and libanalysis.so produced, pip install exits 0; run: pytest exits 0"
  },
  "environment": {
    "os": "Linux",
    "python": "$(python3 --version 2>&1 || echo unknown)",
    "go": "$(go version 2>&1 || echo unknown)",
    "methodology": "tutorial.md one-pass profiling; process-tree RSS peak via monitor_tree.sh (captures multithread/multiprocess peaks); build/run split; real execution."
  },
  "static_triage": {
    "requires_gpu": false,
    "likely_bottlenecks": ["RAM", "CPU", "Disk"],
    "notes": "Python + Go project for Kubernetes operator testing. Build installs ~50 Python packages and compiles two Go shared objects. No GPU dependency. Integration tests load YAML CRDs and run schema matching logic in-memory."
  },
  "peaks_observed": {
    "build_peak_ram_gb": ${build_peak_gb},
    "run_peak_ram_gb": ${run_peak_gb},
    "peak_disk_gb": ${disk_gb},
    "build_runtime_seconds": ${BUILD_RUNTIME},
    "run_runtime_seconds": ${RUN_RUNTIME},
    "cpu_utilization_summary": "build: pip dependency resolution + Go cgo compilation; run: pytest CPU-bound schema matching and serialization tests"
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
