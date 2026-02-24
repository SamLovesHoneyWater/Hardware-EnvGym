#!/bin/bash
# ponylang/ponyc 最小硬件测量（全新流程，参考 tutorial.md）
# 进程树 RSS 峰值用 monitor_tree.sh；测量结束清理工作目录与临时文件

# 确保 cmake 在 PATH（你已安装的便携版或系统）
for d in /home/cc/Label/cmake_portable/cmake-3.28.3-linux-x86_64/bin /home/cc/Label/cmake_portable/bin /usr/local/bin "$HOME/.local/bin" /usr/bin; do
  [ -x "$d/cmake" ] && export PATH="$d:$PATH" && break
  [ -x "$d/cmake3" ] && export PATH="$d:$PATH" && break
done
# LLVM 构建需要 Python 3（支持 conda/miniforge 未 activate 时）
for py in python3 "$HOME/miniforge3/bin/python3" "$HOME/miniconda3/bin/python3" "$HOME/anaconda3/bin/python3" python3.9 python3.8 python3.7 python3.6 /usr/libexec/platform-python3 /usr/bin/python3; do
  [ -x "$py" ] && PY3=$py && break
  [ -x "$(command -v "$py" 2>/dev/null)" ] && PY3=$(command -v "$py") && break
done
[ -n "${PY3:-}" ] && export CMAKE_FLAGS="${CMAKE_FLAGS:-} -DPython3_EXECUTABLE=$PY3"
[ -z "${PY3:-}" ] && echo "警告: 未检测到 Python 3，LLVM 构建将失败；安装 python3 后重跑可获得完整测量。"
# LLVM 需要 GCC>=7.4；优先使用 devtoolset 或 gcc-7+
for g in /opt/rh/devtoolset-9/root/usr/bin/gcc /opt/rh/devtoolset-8/root/usr/bin/gcc /opt/rh/devtoolset-7/root/usr/bin/gcc; do
  [ -x "$g" ] && export CC="$g" CXX="${g/gcc/g++}" && echo "使用: CC=$CC" && break
done
[ -z "${CC:-}" ] && [ -x /usr/bin/gcc-8 ] && export CC=/usr/bin/gcc-8 CXX=/usr/bin/g++-8 && echo "使用: CC=$CC"

REPO_URL="https://github.com/ponylang/ponyc"
WORK_DIR="/home/cc/Label/ponyc_measure_work"
RESULT_DIR="/home/cc/Label/result"
MONITOR="/home/cc/Label/monitor_tree.sh"

mkdir -p "$RESULT_DIR"

echo "[1/5] Clone..."
rm -rf "$WORK_DIR"
git clone --depth 1 "$REPO_URL" "$WORK_DIR"
cd "$WORK_DIR"

echo "[2/5] Submodules..."
git submodule update --init --recursive

# ponyc lib/CMakeLists: 旧版 git 不支持 submodule update --depth 1，且需在仓库根执行
sed -i 's|WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}|WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}/..|g' lib/CMakeLists.txt 2>/dev/null || true
sed -i 's| submodule update --init --recursive --depth 1| submodule update --init --recursive|g' lib/CMakeLists.txt 2>/dev/null || true
sed -i 's|--depth 1 failed with|failed with|g' lib/CMakeLists.txt 2>/dev/null || true

echo "[3/5] Build (make libs && make configure && make build) + 进程树峰值监控..."
build_start=$(date +%s)
export GIT_DIR="$WORK_DIR/.git" GIT_WORK_TREE="$WORK_DIR"
( make libs && make configure && make build ) &
bpid=$!
sleep 3
"$MONITOR" "$bpid" "$RESULT_DIR/ponyc_build" &
mpid=$!
wait $bpid
build_exit=$?
wait $mpid 2>/dev/null || true
build_end=$(date +%s)
build_runtime=$((build_end - build_start))

build_peak_gb=0
if [ -f "$RESULT_DIR/ponyc_build.peaks" ]; then
  build_peak_gb=$(grep '^PEAK_RAM_GB=' "$RESULT_DIR/ponyc_build.peaks" | cut -d= -f2)
fi
[[ "$build_peak_gb" = .* ]] && build_peak_gb="0$build_peak_gb"

echo "[4/5] Run (make test) + 进程树峰值监控..."
run_start=$(date +%s)
make test &
rpid=$!
sleep 2
"$MONITOR" "$rpid" "$RESULT_DIR/ponyc_run" &
mpid=$!
wait $rpid
run_exit=$?
wait $mpid 2>/dev/null || true
run_end=$(date +%s)
run_runtime=$((run_end - run_start))

run_peak_gb=0
if [ -f "$RESULT_DIR/ponyc_run.peaks" ]; then
  run_peak_gb=$(grep '^PEAK_RAM_GB=' "$RESULT_DIR/ponyc_run.peaks" | cut -d= -f2)
fi
[[ "$run_peak_gb" = .* ]] && run_peak_gb="0$run_peak_gb"

disk_kb=$(du -sk "$WORK_DIR" | awk '{print $1}')
peak_disk_gb=$(echo "scale=4; $disk_kb/1024/1024" | bc -l)

round_ram() {
  local v; v=$(echo "$1" | awk '{print int($1)}')
  if [ "${v:-0}" -lt 1 ]; then echo 2
  elif [ "$v" -lt 2 ]; then echo 2
  elif [ "$v" -lt 4 ]; then echo 4
  elif [ "$v" -lt 8 ]; then echo 8
  elif [ "$v" -lt 16 ]; then echo 16
  else echo 16; fi
}
round_disk() {
  local v; v=$(echo "$1" | awk '{print int($1)}')
  if [ "${v:-0}" -lt 1 ]; then echo 1
  elif [ "$v" -lt 2 ]; then echo 2
  elif [ "$v" -lt 4 ]; then echo 4
  elif [ "$v" -lt 8 ]; then echo 8
  else echo 8; fi
}

min_ram=$(round_ram "$build_peak_gb")
rram=$(round_ram "$run_peak_gb")
[ "$rram" -gt "$min_ram" ] && min_ram=$rram
min_disk=$(round_disk "$peak_disk_gb")

echo "[5/5] 写 result/ponylang_ponyc.json ..."
cat > "$RESULT_DIR/ponylang_ponyc.json" << OUT
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
    "methodology": "tutorial.md one-pass profiling; process-tree RSS peak (monitor_tree.sh), whole tree not single process; MVW actually run."
  },
  "static_triage": {
    "requires_gpu": false,
    "likely_bottlenecks": ["RAM", "CPU", "Disk"]
  },
  "peaks_observed": {
    "build_peak_ram_gb": $build_peak_gb,
    "run_peak_ram_gb": $run_peak_gb,
    "peak_disk_gb": $peak_disk_gb,
    "build_runtime_seconds": $build_runtime,
    "run_runtime_seconds": $run_runtime,
    "cpu_utilization_summary": "build high (parallel make/ninja, LLVM); run moderate (test suite)"
  },
  "margins_used": "none",
  "min_hardware": {
    "build_min_spec": { "min_ram_gb": $(round_ram "$build_peak_gb"), "min_disk_gb": $min_disk, "min_vcpu": 2 },
    "run_min_spec": { "min_ram_gb": $(round_ram "$run_peak_gb"), "min_disk_gb": $min_disk, "min_vcpu": 2 },
    "summary": "2 vCPU / $min_ram GB RAM / $min_disk GB disk, no GPU. Raw peaks: build ${build_peak_gb} GB, run ${run_peak_gb} GB, disk ${peak_disk_gb} GB."
  }
}
OUT

echo "清理资源..."
rm -rf "$WORK_DIR"
rm -f "$RESULT_DIR/ponyc_build" "$RESULT_DIR/ponyc_build.peaks" "$RESULT_DIR/ponyc_run" "$RESULT_DIR/ponyc_run.peaks"

echo "Done. Build peak: ${build_peak_gb} GB, Run peak: ${run_peak_gb} GB, Disk: ${peak_disk_gb} GB -> $RESULT_DIR/ponylang_ponyc.json"
