#!/bin/bash
# Measure minimal hardware for sveltejs/svelte with real workload execution.
set -euo pipefail

REPO_URL="https://github.com/sveltejs/svelte"
REPO_NAME="sveltejs_svelte"
WORK_DIR="/home/cc/Label/${REPO_NAME}_measure"
RESULT_DIR="/home/cc/Label/result"
MONITOR="/home/cc/Label/monitor_tree.sh"
LOG_FILE="${RESULT_DIR}/${REPO_NAME}_measure.log"
RESULT_JSON="${RESULT_DIR}/${REPO_NAME}.json"

mkdir -p "$RESULT_DIR"
rm -f "$LOG_FILE"

cleanup() {
  echo "=== cleaning resources ===" | tee -a "$LOG_FILE"
  rm -rf "$WORK_DIR"
  rm -f "${RESULT_DIR}/${REPO_NAME}_build" "${RESULT_DIR}/${REPO_NAME}_build.peaks"
  rm -f "${RESULT_DIR}/${REPO_NAME}_run" "${RESULT_DIR}/${REPO_NAME}_run.peaks"
}
trap cleanup EXIT

round_ram() {
  local v="${1:-0}"
  local i
  i=$(echo "$v" | awk '{print int($1)}')
  if [ "$i" -lt 2 ]; then echo 2
  elif [ "$i" -lt 4 ]; then echo 4
  elif [ "$i" -lt 8 ]; then echo 8
  elif [ "$i" -lt 16 ]; then echo 16
  else echo $(( (i/8+1)*8 ))
  fi
}

round_disk() {
  local v="${1:-0}"
  local i
  i=$(echo "$v" | awk '{print int($1)}')
  if [ "$i" -lt 1 ]; then echo 1
  elif [ "$i" -lt 2 ]; then echo 2
  elif [ "$i" -lt 4 ]; then echo 4
  elif [ "$i" -lt 8 ]; then echo 8
  else echo $(( (i/8+1)*8 ))
  fi
}

read_peak_gb() {
  local base="$1"
  local peak="0"
  if [ -f "${base}.peaks" ]; then
    peak=$(awk -F= '/^PEAK_RAM_GB=/{print $2}' "${base}.peaks")
  fi
  if [ -z "$peak" ] || [ "$peak" = "0" ] || [ "$peak" = "0.0000" ]; then
    if [ -f "$base" ]; then
      local max_kb
      max_kb=$(awk -F, 'NR>1 && $2+0>m {m=$2+0} END {print m+0}' "$base")
      if [ -n "${max_kb:-}" ] && [ "${max_kb:-0}" -gt 0 ] 2>/dev/null; then
        peak=$(echo "scale=4; $max_kb/1024/1024" | bc -l | sed 's/^\./0./')
      fi
    fi
  fi
  [ -z "$peak" ] && peak="0"
  echo "$peak"
}

echo "=== [1/4] clone repository ===" | tee -a "$LOG_FILE"
rm -rf "$WORK_DIR"
git clone --depth 1 "$REPO_URL" "$WORK_DIR" 2>&1 | tee -a "$LOG_FILE"

echo "=== environment ===" | tee -a "$LOG_FILE"
echo "node: $(node -v)" | tee -a "$LOG_FILE"
echo "pnpm: $(pnpm -v)" | tee -a "$LOG_FILE"

echo "=== [2/4] build phase: pnpm install --frozen-lockfile ===" | tee -a "$LOG_FILE"
BUILD_START=$(date +%s.%N)
(
  cd "$WORK_DIR"
  pnpm install --frozen-lockfile
) 2>&1 | tee -a "$LOG_FILE" &
BUILD_PID=$!
sleep 1
BUILD_PGID=$(ps -o pgid= -p "$BUILD_PID" 2>/dev/null | tr -d ' ' || true)
"$MONITOR" "$BUILD_PID" "${RESULT_DIR}/${REPO_NAME}_build" "$BUILD_PGID" &
MON_BUILD_PID=$!
wait "$BUILD_PID"
wait "$MON_BUILD_PID" || true
BUILD_END=$(date +%s.%N)
BUILD_RUNTIME=$(echo "$BUILD_END - $BUILD_START" | bc -l | awk '{printf "%.2f", $1}')
BUILD_PEAK_GB=$(read_peak_gb "${RESULT_DIR}/${REPO_NAME}_build")
echo "build_peak_ram_gb=${BUILD_PEAK_GB}" | tee -a "$LOG_FILE"

echo "=== [3/4] run phase: pnpm exec vitest run --exclude packages/svelte/tests/runtime-browser/test.ts ===" | tee -a "$LOG_FILE"
RUN_START=$(date +%s.%N)
(
  cd "$WORK_DIR"
  pnpm exec vitest run --exclude packages/svelte/tests/runtime-browser/test.ts
) 2>&1 | tee -a "$LOG_FILE" &
RUN_PID=$!
sleep 1
RUN_PGID=$(ps -o pgid= -p "$RUN_PID" 2>/dev/null | tr -d ' ' || true)
"$MONITOR" "$RUN_PID" "${RESULT_DIR}/${REPO_NAME}_run" "$RUN_PGID" &
MON_RUN_PID=$!
wait "$RUN_PID"
wait "$MON_RUN_PID" || true
RUN_END=$(date +%s.%N)
RUN_RUNTIME=$(echo "$RUN_END - $RUN_START" | bc -l | awk '{printf "%.2f", $1}')
RUN_PEAK_GB=$(read_peak_gb "${RESULT_DIR}/${REPO_NAME}_run")
echo "run_peak_ram_gb=${RUN_PEAK_GB}" | tee -a "$LOG_FILE"

DISK_KB=$(du -sk "$WORK_DIR" 2>/dev/null | awk '{print $1}')
DISK_GB=$(echo "scale=4; ${DISK_KB:-0}/1024/1024" | bc -l | sed 's/^\./0./')
[ -z "$DISK_GB" ] && DISK_GB="0"

BUILD_MIN_RAM=$(round_ram "$BUILD_PEAK_GB")
RUN_MIN_RAM=$(round_ram "$RUN_PEAK_GB")
MIN_RAM=$BUILD_MIN_RAM
if [ "$RUN_MIN_RAM" -gt "$MIN_RAM" ]; then
  MIN_RAM=$RUN_MIN_RAM
fi
MIN_DISK=$(round_disk "$DISK_GB")

echo "=== [4/4] write result json ===" | tee -a "$LOG_FILE"
cat > "$RESULT_JSON" <<EOF
{
  "name": "sveltejs_svelte",
  "url": "https://github.com/sveltejs/svelte",
  "mvw": {
    "mvw_command": "pnpm install --frozen-lockfile && pnpm exec vitest run --exclude packages/svelte/tests/runtime-browser/test.ts",
    "build_command": "pnpm install --frozen-lockfile",
    "run_command": "pnpm exec vitest run --exclude packages/svelte/tests/runtime-browser/test.ts",
    "input_scale": "Full repo workspace install and vitest suite excluding Playwright browser-launch file",
    "success_criteria": "exit code 0, vitest reports passing suite"
  },
  "environment": {
    "os": "Linux (CentOS 7)",
    "node": "$(node -v)",
    "pnpm": "$(pnpm -v)",
    "methodology": "tutorial.md one-pass profiling; process-group/tree RSS sampled by monitor_tree.sh every 0.5s; MVW actually executed."
  },
  "static_triage": {
    "requires_gpu": false,
    "likely_bottlenecks": ["RAM", "CPU", "Disk"],
    "notes": "TypeScript/JavaScript monorepo using pnpm and vitest; no explicit GPU requirement. Browser-launch test file is excluded because it requires preinstalled Playwright browser binaries."
  },
  "peaks_observed": {
    "build_peak_ram_gb": ${BUILD_PEAK_GB},
    "run_peak_ram_gb": ${RUN_PEAK_GB},
    "peak_disk_gb": ${DISK_GB},
    "build_runtime_seconds": ${BUILD_RUNTIME},
    "run_runtime_seconds": ${RUN_RUNTIME},
    "cpu_utilization_summary": "build and test phases are CPU-intensive with multiple worker processes"
  },
  "margins_used": "none",
  "min_hardware": {
    "build_min_spec": { "min_ram_gb": ${BUILD_MIN_RAM}, "min_disk_gb": ${MIN_DISK}, "min_vcpu": 2 },
    "run_min_spec": { "min_ram_gb": ${RUN_MIN_RAM}, "min_disk_gb": ${MIN_DISK}, "min_vcpu": 2 },
    "summary": "2 vCPU / ${MIN_RAM} GB RAM / ${MIN_DISK} GB disk, no GPU. Raw process-tree peaks: build ${BUILD_PEAK_GB} GB, run ${RUN_PEAK_GB} GB, disk ${DISK_GB} GB."
  }
}
EOF

echo "done: ${RESULT_JSON}" | tee -a "$LOG_FILE"
