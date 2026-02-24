#!/bin/bash
# Read result/grpc_grpc-go_peaks.txt (from measure_grpc_ram.sh), recompute min_hardware, write result/grpc_grpc-go.json
set -e
LABEL="$(cd "$(dirname "$0")" && pwd)"
PEAKS=$LABEL/result/grpc_grpc-go_peaks.txt
JSON=$LABEL/result/grpc_grpc-go.json

if [ ! -f "$PEAKS" ]; then
  echo "Run first: bash $LABEL/measure_grpc_ram.sh"
  exit 1
fi

python3 "$LABEL/update_grpc_json.py" "$PEAKS" "$JSON"
echo "Updated $JSON with measured peaks and min_hardware."
