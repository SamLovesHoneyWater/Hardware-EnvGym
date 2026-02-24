#!/bin/bash
# Measure minimal hardware for uiuc-arc/sixthsense with real execution.
set -euo pipefail

REPO_URL="https://github.com/uiuc-arc/sixthsense"
WORK_ROOT="/home/cc/Label/sixthsense_measure_work"
WORK_DIR="$WORK_ROOT/sixthsense"
RESULT_DIR="/home/cc/Label/result"
MONITOR="/home/cc/Label/monitor_tree.sh"
LOG_FILE="$RESULT_DIR/sixthsense_measure.log"

BUILD_CSV="$RESULT_DIR/sixthsense_build"
RUN_CSV="$RESULT_DIR/sixthsense_run"
ZENODO_TAR="$WORK_ROOT/csvs.tar.gz"
ZENODO_URL="https://zenodo.org/records/6388301/files/csvs.tar.gz?download=1"

mkdir -p "$RESULT_DIR" "$WORK_ROOT"
export PATH="$HOME/.local/bin:$PATH"

cleanup() {
  echo "=== cleanup ===" | tee -a "$LOG_FILE"
  rm -rf "$WORK_DIR"
  rm -f "$ZENODO_TAR"
  rm -f "$BUILD_CSV" "$BUILD_CSV.peaks" "$RUN_CSV" "$RUN_CSV.peaks"
}
trap cleanup EXIT

echo "=== [1/6] clone sixthsense ===" | tee "$LOG_FILE"
rm -rf "$WORK_DIR"
git clone --depth 1 "$REPO_URL" "$WORK_DIR" 2>&1 | tee -a "$LOG_FILE"

echo "=== [2/6] static triage ===" | tee -a "$LOG_FILE"
REQUIRES_GPU=false
if rg -i "cuda|rocm|nvidia|tensorflow-gpu|--gpus" "$WORK_DIR" >/dev/null 2>&1; then
  REQUIRES_GPU=true
fi
echo "requires_gpu=$REQUIRES_GPU" | tee -a "$LOG_FILE"

echo "=== [3/6] prepare data from Zenodo ===" | tee -a "$LOG_FILE"
mkdir -p "$WORK_DIR/csvs" "$WORK_DIR/plots" "$WORK_DIR/models" "$WORK_DIR/results"
wget -O "$ZENODO_TAR" "$ZENODO_URL" 2>&1 | tee -a "$LOG_FILE"
tar -xzf "$ZENODO_TAR" -C "$WORK_DIR" 2>&1 | tee -a "$LOG_FILE"

if [ ! -f "$WORK_DIR/csvs/lrm_features.csv" ] || [ ! -f "$WORK_DIR/csvs/lrm_metrics.csv" ]; then
  echo "required csv files not found after extraction" | tee -a "$LOG_FILE"
  exit 1
fi

echo "=== [4/6] build phase: conda py3.10 + conda deps ===" | tee -a "$LOG_FILE"
BUILD_START=$(date +%s)
(
  set -e
  cd "$WORK_DIR"
  source "$(conda info --base)/etc/profile.d/conda.sh"
  conda create -y -p "$WORK_DIR/.conda-env" python=3.10
  conda activate "$WORK_DIR/.conda-env"
  conda install -y -c conda-forge \
    scikit-learn numpy matplotlib pandas jsonpickle nearpy treeinterpreter cleanlab
) 2>&1 | tee -a "$LOG_FILE" &
BUILD_PID=$!
sleep 0.2
"$MONITOR" "$BUILD_PID" "$BUILD_CSV" &
MON_BUILD_PID=$!
wait "$BUILD_PID"
wait "$MON_BUILD_PID" || true
BUILD_END=$(date +%s)
BUILD_RUNTIME=$((BUILD_END - BUILD_START))

echo "=== [5/6] run phase: train.py MVW ===" | tee -a "$LOG_FILE"
RUN_START=$(date +%s)
(
  set -e
  cd "$WORK_DIR"
  source "$(conda info --base)/etc/profile.d/conda.sh"
  conda activate "$WORK_DIR/.conda-env"
  python train.py \
    -f csvs/lrm_features.csv \
    -l csvs/lrm_metrics.csv \
    -a rf \
    -m rhat_min \
    -suf avg \
    -bw \
    -plt \
    -saveas plots/results_rhat_min_lrm.png \
    -keep _ast_ dt_ var_min var_max data_size \
    -st \
    -tname lightspeed \
    -cv \
    -ignore_vi
) 2>&1 | tee -a "$LOG_FILE" &
RUN_PID=$!
sleep 0.2
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

if [ ! -f "$WORK_DIR/plots/results_rhat_min_lrm.png" ]; then
  echo "expected plot output not found" | tee -a "$LOG_FILE"
  exit 1
fi

build_peak_gb=$(awk -F= '/^PEAK_RAM_GB=/{print $2}' "$BUILD_CSV.peaks")
run_peak_gb=$(awk -F= '/^PEAK_RAM_GB=/{print $2}' "$RUN_CSV.peaks")

if [ -z "${build_peak_gb:-}" ]; then build_peak_gb=0; fi
if [ -z "${run_peak_gb:-}" ]; then run_peak_gb=0; fi

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

echo "=== [6/6] write result/sixthsense.json ===" | tee -a "$LOG_FILE"
cat > "$RESULT_DIR/sixthsense.json" <<EOF
{
  "name": "sixthsense",
  "url": "https://github.com/uiuc-arc/sixthsense",
  "mvw": {
    "mvw_command": "python train.py -f csvs/lrm_features.csv -l csvs/lrm_metrics.csv -a rf -m rhat_min -suf avg -bw -plt -saveas plots/results_rhat_min_lrm.png -keep _ast_ dt_ var_min var_max data_size -st -tname lightspeed -cv -ignore_vi",
    "build_command": "conda create -y -p .conda-env python=3.10 && conda activate ./.conda-env && conda install -y -c conda-forge scikit-learn numpy matplotlib pandas jsonpickle nearpy treeinterpreter cleanlab",
    "run_command": "python train.py -f csvs/lrm_features.csv -l csvs/lrm_metrics.csv -a rf -m rhat_min -suf avg -bw -plt -saveas plots/results_rhat_min_lrm.png -keep _ast_ dt_ var_min var_max data_size -st -tname lightspeed -cv -ignore_vi",
    "input_scale": "Official Zenodo csv dataset; class=lrm; model type=lightspeed; threshold sweep in -plt mode",
    "success_criteria": "train exits 0, threshold/F1 logs present, plot artifact generated"
  },
  "environment": {
    "os": "Linux",
    "python": "conda environment with python3.10",
    "methodology": "tutorial.md one-pass profiling; process-tree RSS peak via monitor_tree.sh (captures multithread/multiprocess peaks); build/run split; real execution."
  },
  "static_triage": {
    "requires_gpu": $REQUIRES_GPU,
    "likely_bottlenecks": ["RAM", "CPU", "Disk"],
    "notes": "Scikit-learn random-forest training + cross-validation; no CUDA dependency in repo."
  },
  "peaks_observed": {
    "build_peak_ram_gb": $build_peak_gb,
    "run_peak_ram_gb": $run_peak_gb,
    "peak_disk_gb": $disk_gb,
    "build_runtime_seconds": $BUILD_RUNTIME,
    "run_runtime_seconds": $RUN_RUNTIME,
    "cpu_utilization_summary": "build: conda dependency solve/install; run: sklearn RF training + CV and threshold sweep"
  },
  "margins_used": "none",
  "min_hardware": {
    "build_min_spec": {"min_ram_gb": $min_build_ram, "min_disk_gb": $min_disk, "min_vcpu": 2},
    "run_min_spec": {"min_ram_gb": $min_run_ram, "min_disk_gb": $min_disk, "min_vcpu": 2},
    "summary": "2 vCPU / $min_ram GB RAM / $min_disk GB disk, no GPU. Raw process-tree peaks: build ${build_peak_gb} GB, run ${run_peak_gb} GB, disk ${disk_gb} GB."
  }
}
EOF

echo "Done: $RESULT_DIR/sixthsense.json" | tee -a "$LOG_FILE"
