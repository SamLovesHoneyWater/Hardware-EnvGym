#!/bin/bash
# Run all repo measurements (process-tree RSS + disk) and update result JSONs.
# Execute on your machine: bash /path/to/Label/run_all_measurements.sh
# Requires: git, go (for grpc), mvn (for gluetest), make (for zstd), cmake/ctest (for fmt), pip/python3 (for flex)
set -e
LABEL="$(cd "$(dirname "$0")" && pwd)"
cd "$LABEL"
mkdir -p result

run_one() {
  local name=$1
  local measure_script=$2
  local peaks_file=$3
  local json_file=$4
  echo "===== Measuring $name ====="
  if ! bash "$measure_script"; then
    echo "WARN: $name measurement failed, skip update"
    return 1
  fi
  if [ -f "$peaks_file" ]; then
    python3 "$LABEL/update_result_from_peaks.py" "$peaks_file" "$json_file" || true
  else
    echo "WARN: $peaks_file not found, skip update"
  fi
}

# grpc-go: has its own updater (update_grpc_result_from_peaks.sh + update_grpc_json.py)
echo "===== Measuring grpc_grpc-go ====="
if bash "$LABEL/measure_grpc_ram.sh"; then
  [ -f "$LABEL/result/grpc_grpc-go_peaks.txt" ] && bash "$LABEL/update_grpc_result_from_peaks.sh" || true
fi

# gluetest
run_one gluetest "$LABEL/measure_gluetest.sh" "$LABEL/result/gluetest_peaks.txt" "$LABEL/result/gluetest.json"

# facebook_zstd
run_one facebook_zstd "$LABEL/measure_facebook_zstd.sh" "$LABEL/result/facebook_zstd_peaks.txt" "$LABEL/result/facebook_zstd.json"

# fmtlib_fmt
run_one fmtlib_fmt "$LABEL/measure_fmtlib_fmt.sh" "$LABEL/result/fmtlib_fmt_peaks.txt" "$LABEL/result/fmtlib_fmt.json"

# flex
run_one flex "$LABEL/measure_flex.sh" "$LABEL/result/flex_peaks.txt" "$LABEL/result/flex.json"

echo "===== Done ====="
