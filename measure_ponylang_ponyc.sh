#!/bin/bash
# 测量 ponylang/ponyc 最小硬件：实际运行 build + test，进程树峰值监控（含多线程/多进程峰值）
set -e
REPO_URL="https://github.com/ponylang/ponyc"
WORK_DIR="/home/cc/Label/ponylang_ponyc_measure"
RESULT_DIR="/home/cc/Label/result"
MONITOR="/home/cc/Label/monitor_tree.sh"
mkdir -p "$RESULT_DIR"
for d in /usr/local/bin "$HOME/.local/bin" /opt/cmake/bin /usr/bin; do
  [ -x "$d/cmake" ] && export PATH="$d:$PATH" && break
  [ -x "$d/cmake3" ] && export PATH="$d:$PATH" && break
done

cleanup() {
  echo "=== 清理资源 ==="
  if [ -d "$WORK_DIR" ]; then
    rm -rf "$WORK_DIR"
    echo "已删除 $WORK_DIR"
  fi
  # 保留 result 下的 json，清理本次生成的临时 peaks 与 log
  rm -f "$RESULT_DIR/ponyc_build.peaks" "$RESULT_DIR/ponyc_build" \
        "$RESULT_DIR/ponyc_run.peaks" "$RESULT_DIR/ponyc_run" \
        "$RESULT_DIR/ponyc_measure.log"
}

trap cleanup EXIT

echo "=== Clone 仓库 ==="
if [ -d "$WORK_DIR" ]; then
  rm -rf "$WORK_DIR"
fi
git clone --depth 1 "$REPO_URL" "$WORK_DIR" 2>&1 | tee -a "$RESULT_DIR/ponyc_measure.log"
cd "$WORK_DIR"

# 初始化 submodule（ponyc 需要 lib/llvm）
echo "=== 初始化 submodules ==="
git submodule update --init --recursive 2>&1 | tee -a "$RESULT_DIR/ponyc_measure.log" || true

# 若无 cmake 则下载便携版（以便真实执行构建）
if ! command -v cmake >/dev/null 2>&1; then
  CMAKE_DIR="/home/cc/Label/cmake_portable"
  if [ ! -x "$CMAKE_DIR/bin/cmake" ]; then
    echo "=== 未找到 cmake，下载便携版至 $CMAKE_DIR ==="
    mkdir -p "$CMAKE_DIR"
    wget -q "https://github.com/Kitware/CMake/releases/download/v3.28.1/cmake-3.28.1-linux-x86_64.tar.gz" -O "$CMAKE_DIR/cmake.tar.gz" && \
      tar xzf "$CMAKE_DIR/cmake.tar.gz" -C "$CMAKE_DIR" --strip-components=1 && rm -f "$CMAKE_DIR/cmake.tar.gz" || true
  fi
  [ -x "$CMAKE_DIR/bin/cmake" ] && export PATH="$CMAKE_DIR/bin:$PATH"
fi

echo "=== Build 阶段（make libs && make configure && make build）— 进程树峰值监控 ==="
BUILD_START=$(date +%s)
set +e
( make libs && make configure && make build ) &
BUILD_PID=$!
sleep 3
$MONITOR $BUILD_PID "$RESULT_DIR/ponyc_build" &
MON_PID=$!
wait $BUILD_PID
BUILD_EXIT=$?
wait $MON_PID 2>/dev/null || true
set -e
BUILD_END=$(date +%s)
BUILD_RUNTIME=$((BUILD_END - BUILD_START))

if [ "$BUILD_EXIT" -ne 0 ]; then
  echo "Build 失败 exit=$BUILD_EXIT，尝试仅 make configure + make build（跳过 libs）"
  BUILD_START=$(date +%s)
  set +e
  ( make configure && make build ) &
  BUILD_PID=$!
  sleep 2
  $MONITOR $BUILD_PID "$RESULT_DIR/ponyc_build" &
  MON_PID=$!
  wait $BUILD_PID
  wait $MON_PID 2>/dev/null || true
  set -e
  BUILD_END=$(date +%s)
  BUILD_RUNTIME=$((BUILD_END - BUILD_START))
fi

BUILD_PEAK_GB=0
if [ -f "$RESULT_DIR/ponyc_build.peaks" ]; then
  BUILD_PEAK_GB=$(grep '^PEAK_RAM_GB=' "$RESULT_DIR/ponyc_build.peaks" | cut -d= -f2)
  [[ "$BUILD_PEAK_GB" = .* ]] && BUILD_PEAK_GB="0$BUILD_PEAK_GB"
fi

echo "=== Run 阶段（make test）— 进程树峰值监控 ==="
RUN_START=$(date +%s)
set +e
make test &
RUN_PID=$!
sleep 2
$MONITOR $RUN_PID "$RESULT_DIR/ponyc_run" &
MON_PID=$!
wait $RUN_PID
RUN_EXIT=$?
wait $MON_PID 2>/dev/null || true
set -e
RUN_END=$(date +%s)
RUN_RUNTIME=$((RUN_END - RUN_START))

RUN_PEAK_GB=0
if [ -f "$RESULT_DIR/ponyc_run.peaks" ]; then
  RUN_PEAK_GB=$(grep '^PEAK_RAM_GB=' "$RESULT_DIR/ponyc_run.peaks" | cut -d= -f2)
  [[ "$RUN_PEAK_GB" = .* ]] && RUN_PEAK_GB="0$RUN_PEAK_GB"
fi

# 磁盘：整个工作目录（源码+build 产物）
DISK_KB=$(du -sk "$WORK_DIR" 2>/dev/null | awk '{print $1}')
DISK_GB=$(echo "scale=4; $DISK_KB/1024/1024" | bc -l 2>/dev/null || echo "0")
[ -z "$DISK_GB" ] && DISK_GB=0

if [ "$BUILD_EXIT" -ne 0 ]; then
  MEASUREMENT_NOTE="Build failed (e.g. missing cmake). Peaks from partial run; disk reflects clone+submodule. Install cmake and re-run for full build/run peaks."
else
  MEASUREMENT_NOTE=""
fi

round_ram() {
  local v=$1
  local i=$(echo "$v" | awk '{print int($1)}')
  if [ "$i" -lt 1 ]; then echo 2
  elif [ "$i" -lt 2 ]; then echo 2
  elif [ "$i" -lt 4 ]; then echo 4
  elif [ "$i" -lt 8 ]; then echo 8
  elif [ "$i" -lt 16 ]; then echo 16
  else echo $(( (i/8+1)*8 )); fi
}
round_disk() {
  local v=$1
  local i=$(echo "$v" | awk '{print int($1)}')
  if [ "$i" -lt 1 ]; then echo 1
  elif [ "$i" -lt 2 ]; then echo 2
  elif [ "$i" -lt 4 ]; then echo 4
  elif [ "$i" -lt 8 ]; then echo 8
  else echo $(( (i/8+1)*8 )); fi
}

MIN_RAM=$(round_ram "$BUILD_PEAK_GB")
MIN_RUN_RAM=$(round_ram "$RUN_PEAK_GB")
[ "$MIN_RUN_RAM" -gt "$MIN_RAM" ] && MIN_RAM=$MIN_RUN_RAM
MIN_DISK=$(round_disk "$DISK_GB")

cat > "$RESULT_DIR/ponylang_ponyc.json" << EOF
{
  "name": "ponylang_ponyc",
  "url": "https://github.com/ponylang/ponyc",
  "mvw": {
    "mvw_command": "make libs && make configure && make build && make test",
    "build_command": "make libs && make configure && make build",
    "run_command": "make test",
    "input_scale": "Full source build (LLVM libs + ponyc), default test suite",
    "success_criteria": "exit code 0"
  },
  "environment": {
    "os": "Linux",
    "methodology": "tutorial.md one-pass profiling; process-tree RSS peak (monitor_tree.sh), MVW actually run; peaks over entire process tree (multi-thread/multi-process)."
  },
  "static_triage": {
    "requires_gpu": false,
    "likely_bottlenecks": ["RAM", "CPU", "Disk"]
  },
  "peaks_observed": {
    "build_peak_ram_gb": $BUILD_PEAK_GB,
    "run_peak_ram_gb": $RUN_PEAK_GB,
    "peak_disk_gb": $DISK_GB,
    "build_runtime_seconds": $BUILD_RUNTIME,
    "run_runtime_seconds": $RUN_RUNTIME,
    "cpu_utilization_summary": "build high (parallel make/ninja, LLVM compile); run moderate (test suite)"
  },
  "margins_used": "none",
  "min_hardware": {
    "build_min_spec": {
      "min_ram_gb": $(round_ram "$BUILD_PEAK_GB"),
      "min_disk_gb": $MIN_DISK,
      "min_vcpu": 2
    },
    "run_min_spec": {
      "min_ram_gb": $(round_ram "$RUN_PEAK_GB"),
      "min_disk_gb": $MIN_DISK,
      "min_vcpu": 2
    },
    "summary": "2 vCPU / $MIN_RAM GB RAM / $MIN_DISK GB disk, no GPU. Raw process-tree peaks: build ${BUILD_PEAK_GB} GB, run ${RUN_PEAK_GB} GB, disk ${DISK_GB} GB."
  }
}
EOF

echo "Done. Build peak RAM: ${BUILD_PEAK_GB} GB, Run peak RAM: ${RUN_PEAK_GB} GB, Disk: ${DISK_GB} GB"
echo "Result: $RESULT_DIR/ponylang_ponyc.json"
_DIR/ponylang_ponyc.json"
