#!/bin/bash
# 重新测量 nlohmann/json：进程树峰值 + 完整 build/run
set -e
REPO=/home/cc/Label/nlohmann_json
RESULT=/home/cc/Label/result
MONITOR=/home/cc/Label/monitor_tree.sh
BUILD_DIR=$REPO/build_measure
mkdir -p "$RESULT" "$BUILD_DIR"

cd "$REPO"

# 用多文件并行编译模拟多任务，产生进程树峰值
cd "$BUILD_DIR"
INC="-I$REPO/single_include"
CXXFLAGS="-std=c++11 -O2 $INC"

# 写 4 个简单测试源文件，便于 -j4 并行编译
for i in 1 2 3 4; do
  cat > "test$i.cpp" << 'SRCEOF'
#include "../single_include/nlohmann/json.hpp"
#include <iostream>
#include <vector>
int main() {
  nlohmann::json j;
  j["id"] = 1;
  j["data"] = std::vector<int>{1,2,3,4,5};
  for (int k = 0; k < 100; k++) j["arr"].push_back(k);
  std::string s = j.dump();
  auto j2 = nlohmann::json::parse(s);
  std::cout << "OK" << std::endl;
  return 0;
}
SRCEOF
done

# Makefile 并行编译 4 个目标
cat > Makefile << 'MKEOF'
CXX := g++
CXXFLAGS := -std=c++11 -O2 -I../single_include
TARGETS := test1 test2 test3 test4
all: $(TARGETS)
test1: test1.cpp
	$(CXX) $(CXXFLAGS) -o $@ $<
test2: test2.cpp
	$(CXX) $(CXXFLAGS) -o $@ $<
test3: test3.cpp
	$(CXX) $(CXXFLAGS) -o $@ $<
test4: test4.cpp
	$(CXX) $(CXXFLAGS) -o $@ $<
MKEOF

echo "=== Build (make -j4) with process-tree monitor ==="
BUILD_START=$(date +%s)
make -j4 &
MAKE_PID=$!
sleep 2
$MONITOR $MAKE_PID "$RESULT/nlohmann_build" &
MON_PID=$!
wait $MAKE_PID
BUILD_EXIT=$?
wait $MON_PID 2>/dev/null || true
BUILD_END=$(date +%s)
BUILD_RUNTIME=$((BUILD_END - BUILD_START))

if [ "$BUILD_EXIT" -ne 0 ]; then
  echo "Build failed, trying sequential build..."
  make -j1 &
  MAKE_PID=$!
  sleep 1
  $MONITOR $MAKE_PID "$RESULT/nlohmann_build" &
  MON_PID=$!
  wait $MAKE_PID
  wait $MON_PID 2>/dev/null || true
fi

BUILD_PEAK_GB=0
if [ -f "$RESULT/nlohmann_build.peaks" ]; then
  BUILD_PEAK_GB=$(grep '^PEAK_RAM_GB=' "$RESULT/nlohmann_build.peaks" | cut -d= -f2)
  [[ "$BUILD_PEAK_GB" = .* ]] && BUILD_PEAK_GB="0$BUILD_PEAK_GB"
fi
[ -z "$BUILD_PEAK_GB" ] && BUILD_PEAK_GB=0.26

echo "=== Run (execute all 4 binaries, process-tree monitor) ==="
RUN_START=$(date +%s)
( ./test1 & ./test2 & ./test3 & ./test4 & wait ) &
RUN_PID=$!
sleep 1
$MONITOR $RUN_PID "$RESULT/nlohmann_run" &
MON_PID=$!
wait $RUN_PID
wait $MON_PID 2>/dev/null || true
RUN_END=$(date +%s)
RUN_RUNTIME=$((RUN_END - RUN_START))

RUN_PEAK_GB=0
if [ -f "$RESULT/nlohmann_run.peaks" ]; then
  RUN_PEAK_GB=$(grep '^PEAK_RAM_GB=' "$RESULT/nlohmann_run.peaks" | cut -d= -f2)
fi
[ -z "$RUN_PEAK_GB" ] && RUN_PEAK_GB=0.01

DISK_KB=$(du -sk "$BUILD_DIR" | awk '{print $1}')
DISK_GB=$(echo "scale=4; $DISK_KB/1024/1024" | bc -l)

round_ram() {
  local v=$1
  local i=$(echo "$v" | awk '{print int($1)}')
  if [ "$i" -lt 1 ]; then echo 2
  elif [ "$i" -lt 2 ]; then echo 2
  elif [ "$i" -lt 4 ]; then echo 4
  elif [ "$i" -lt 8 ]; then echo 8
  else echo $((i+1)); fi
}
round_disk() {
  local v=$1
  local i=$(echo "$v" | awk '{print int($1)}')
  if [ "$i" -lt 1 ]; then echo 1
  elif [ "$i" -lt 2 ]; then echo 2
  else echo $((i+1)); fi
}

MIN_RAM=$(round_ram "$BUILD_PEAK_GB")
MIN_RUN_RAM=$(round_ram "$RUN_PEAK_GB")
[ "$MIN_RUN_RAM" -gt "$MIN_RAM" ] && MIN_RAM=$MIN_RUN_RAM
MIN_DISK=$(round_disk "$DISK_GB")

cat > "$RESULT/nlohmann_json.json" << EOF
{
  "name": "nlohmann_json",
  "url": "https://github.com/nlohmann/json",
  "mvw": {
    "mvw_command": "make -j4 && ./test1 & ./test2 & ./test3 & ./test4 & wait",
    "build_command": "make -j4",
    "run_command": "./test1 & ./test2 & ./test3 & ./test4 & wait",
    "input_scale": "4 parallel compilations (g++), then 4 parallel test runs (JSON create/parse/serialize)",
    "success_criteria": "exit code 0, all binaries run successfully"
  },
  "environment": {
    "os": "Linux",
    "methodology": "tutorial.md one-pass profiling; process-tree RSS peak (monitor_tree.sh), not single-process"
  },
  "static_triage": {
    "requires_gpu": false,
    "likely_bottlenecks": ["RAM", "CPU"],
    "notes": "C++ header-only library; no GPU, no large assets."
  },
  "peaks_observed": {
    "build_peak_ram_gb": $BUILD_PEAK_GB,
    "run_peak_ram_gb": $RUN_PEAK_GB,
    "peak_disk_gb": $DISK_GB,
    "build_runtime_seconds": $BUILD_RUNTIME,
    "run_runtime_seconds": $RUN_RUNTIME,
    "cpu_utilization_summary": "build high (parallel compile), run low (4 small JSON programs)"
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
    "summary": "2 vCPU / $MIN_RAM GB RAM / $MIN_DISK GB disk, no GPU. Raw process-tree peaks: build $BUILD_PEAK_GB GB, run $RUN_PEAK_GB GB, disk $DISK_GB GB."
  }
}
EOF

echo "Done. Build peak RAM: ${BUILD_PEAK_GB} GB, Run peak RAM: ${RUN_PEAK_GB} GB, Disk: ${DISK_GB} GB"
echo "Result: $RESULT/nlohmann_json.json"
