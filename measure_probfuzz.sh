#!/bin/bash
# 测量 uiuc-arc/probfuzz 最小硬件：实际运行 install + probfuzz.py 1，进程树峰值（含多线程/多进程）
set -e
REPO_URL="https://github.com/uiuc-arc/probfuzz"
WORK_DIR="/home/cc/Label/probfuzz_measure"
RESULT_DIR="/home/cc/Label/result"
MONITOR="/home/cc/Label/monitor_tree.sh"
LOG_FILE="$RESULT_DIR/probfuzz_measure.log"

mkdir -p "$RESULT_DIR"
[ -z "$HOME" ] && export HOME=$(getent passwd "$(whoami)" 2>/dev/null | cut -d: -f6) || true

# 避免 /tmp pip-build 在某些机器上出问题（你日志里就是 /tmp/pip-build... 诡异缺文件）
export TMPDIR="${TMPDIR:-$HOME/.tmp/pip}"
mkdir -p "$TMPDIR"

# 确保 conda 的 java 在 PATH 中（antlr run.sh 需要）
for d in "$HOME/miniforge3/bin" "$HOME/miniconda3/bin" "$HOME/anaconda3/bin" "$HOME/conda/bin" "/home/cc/miniforge3/bin"; do
  [ -x "$d/java" ] && export PATH="$d:$PATH" && break
done

cleanup() {
  echo "=== 清理资源 ==="
  if [ -d "$WORK_DIR" ]; then
    rm -rf "$WORK_DIR"
    echo "已删除 $WORK_DIR"
  fi
  rm -f "$RESULT_DIR/probfuzz_build.peaks" "$RESULT_DIR/probfuzz_build" \
        "$RESULT_DIR/probfuzz_run.peaks" "$RESULT_DIR/probfuzz_run"
  # 保留 result/probfuzz.json 和 probfuzz_measure.log
}

trap cleanup EXIT

echo "=== [1/4] Clone 仓库 ===" | tee "$LOG_FILE"
if [ -d "$WORK_DIR" ]; then
  rm -rf "$WORK_DIR"
fi
git clone --depth 1 "$REPO_URL" "$WORK_DIR" 2>&1 | tee -a "$LOG_FILE"
cd "$WORK_DIR"

# README: 官方安装为 sudo ./install.sh，成功时会打印 "Install successful"（由 check.py 检查 pystan/edward/pyro/tensorflow/torch 等）
# Python 3 兼容：若用 python3 跑 probfuzz.py 才需要改 Queue
if [ -f probfuzz.py ] && grep -q 'import Queue as queue' probfuzz.py 2>/dev/null; then
  python3 -c "
p = 'probfuzz.py'
with open(p) as f: s = f.read()
if 'import Queue as queue' in s and 'except ImportError' not in s:
  s = s.replace('import Queue as queue', '''try:
    import queue
except ImportError:
    import Queue as queue''')
  with open(p,'w') as f: f.write(s)
" 2>/dev/null || true
fi

echo "=== [2/4] Build 阶段（按 README: sudo ./install.sh 或等价依赖）— 进程树峰值监控 ===" | tee -a "$LOG_FILE"
BUILD_START=$(date +%s)

# 官方方式（README）：sudo ./install.sh → 会装 python2.7, pip, bc, pip2 装 antlr4/six/astunparse/ast/pystan/edward/pyro-ppl==0.2.1/tensorflow==1.5.0/pandas + torch 0.4.0 + antlr 生成 + ./check.py
HAS_APT=0
command -v apt-get >/dev/null 2>&1 && HAS_APT=1
HAS_SUDO=0
sudo -n true >/dev/null 2>&1 && HAS_SUDO=1

set +e
if [ "$HAS_APT" = "1" ] && [ "$HAS_SUDO" = "1" ]; then
  echo "按 README 执行: sudo ./install.sh" | tee -a "$LOG_FILE"
  ( sudo ./install.sh 2>&1 || true ) &
else
  echo "无 apt-get 或 sudo，尝试用 pip2 安装与 install.sh 等价的依赖（需 Python 2）..." | tee -a "$LOG_FILE"
  (
    set -e
    PY=python2
    command -v "$PY" >/dev/null 2>&1 || { echo "缺少 python2，Probfuzz 官方要求 Python 2"; exit 1; }
    "$PY" -m pip install --user --upgrade "pip==20.3.4" "setuptools<45" wheel >/dev/null 2>&1 || true
    # 与 install.sh 一致：antlr4 six astunparse ast pystan edward pyro-ppl==0.2.1 tensorflow==1.5.0 pandas
    "$PY" -m pip install --user --no-cache-dir \
      antlr4-python2-runtime six astunparse ast \
      pystan edward pyro-ppl==0.2.1 tensorflow==1.5.0 pandas 2>&1 || true
    # torch 0.4.0（与 install.sh 一致：先 cp27mu，再试 cp27m）
    for whl in "http://download.pytorch.org/whl/cpu/torch-0.4.0-cp27-cp27mu-linux_x86_64.whl" "https://download.pytorch.org/whl/cpu/torch-0.4.0-cp27-cp27mu-linux_x86_64.whl" "https://download.pytorch.org/whl/cpu/torch-0.4.0-cp27-cp27m-linux_x86_64.whl"; do
      "$PY" -m pip install --user "$whl" 2>&1 && break || true
    done
    # antlr 生成（与 language/antlr/run.sh 一致：-package tool.parser）
    ANTLR_DIR="$WORK_DIR/language/antlr"
    JAVA_CMD="$(command -v java 2>/dev/null || true)"
    if [ -d "$ANTLR_DIR" ] && [ -n "$JAVA_CMD" ]; then
      cd "$ANTLR_DIR"
      wget -q https://www.antlr.org/download/antlr-4.7.1-complete.jar -O antlr-4.7.1-complete.jar 2>/dev/null || true
      "$JAVA_CMD" -Xmx500M -cp ".:./antlr-4.7.1-complete.jar:$CLASSPATH" org.antlr.v4.Tool -package "tool.parser" -Dlanguage=Python2 -visitor Template.g4 2>/dev/null || true
      touch __init__.py 2>/dev/null || true
    fi
  ) 2>&1 | tee -a "$LOG_FILE" &
fi

BUILD_PID=$!
sleep 1
$MONITOR "$BUILD_PID" "$RESULT_DIR/probfuzz_build" &
MON_PID=$!
wait $BUILD_PID 2>/dev/null || true
wait $MON_PID 2>/dev/null || true
set -e

BUILD_END=$(date +%s)
BUILD_RUNTIME=$((BUILD_END - BUILD_START))

# README：install 成功时 check.py 会打印 "Install successful"，否则无法真正跑 Stan/Edward/Pyro
CHECK_OUT="$RESULT_DIR/check_output.txt"
CHECK_OK=0
for py in python2 python3 python; do
  command -v "$py" >/dev/null 2>&1 || continue
  "$py" ./check.py >"$CHECK_OUT" 2>&1
  if grep -q "Install successful" "$CHECK_OUT"; then
    CHECK_OK=1
    cat "$CHECK_OUT" | tee -a "$LOG_FILE"
    break
  fi
done
if [ "$CHECK_OK" -ne 1 ]; then
  echo "" | tee -a "$LOG_FILE"
  echo "=== 安装未成功（check.py 未输出 'Install successful'）===" | tee -a "$LOG_FILE"
  echo "README 要求: 在 Debian/Ubuntu 上执行: sudo ./install.sh" | tee -a "$LOG_FILE"
  echo "install.sh 会安装: python2.7, pip, bc, 以及 pip2 包: antlr4, six, astunparse, ast, pystan, edward, pyro-ppl==0.2.1, tensorflow==1.5.0, pandas, torch 0.4.0 + antlr 生成。" | tee -a "$LOG_FILE"
  echo "当前 check 输出:" | tee -a "$LOG_FILE"
  cat "$CHECK_OUT" 2>/dev/null | tee -a "$LOG_FILE" || true
  cat > "$RESULT_DIR/probfuzz.json" << EOF
{
  "name": "probfuzz",
  "url": "https://github.com/uiuc-arc/probfuzz",
  "install_success": false,
  "note": "check.py did not print 'Install successful'. Use sudo ./install.sh on Debian/Ubuntu per README."
}
EOF
  echo "已写入 $RESULT_DIR/probfuzz.json（install_success: false）" | tee -a "$LOG_FILE"
  exit 1
fi
echo "check.py 输出 'Install successful'，继续 Run 阶段。" | tee -a "$LOG_FILE"

BUILD_PEAK_GB=0
if [ -f "$RESULT_DIR/probfuzz_build.peaks" ]; then
  BUILD_PEAK_GB=$(grep '^PEAK_RAM_GB=' "$RESULT_DIR/probfuzz_build.peaks" | cut -d= -f2)
  [[ "$BUILD_PEAK_GB" = .* ]] && BUILD_PEAK_GB="0$BUILD_PEAK_GB"
fi
# peaks 为 0 时，从 csv 回退取最大 RSS
if [ -f "$RESULT_DIR/probfuzz_build" ] && { [ "${BUILD_PEAK_GB:-0}" = "0" ] || [ "${BUILD_PEAK_GB:-0}" = "0.0000" ]; }; then
  MAX_KB=$(awk -F, 'NR>1 && $2+0>m {m=$2+0} END {print m+0}' "$RESULT_DIR/probfuzz_build" 2>/dev/null)
  if [ -n "$MAX_KB" ] && [ "$MAX_KB" -gt 0 ] 2>/dev/null; then
    BUILD_PEAK_GB=$(echo "scale=4; $MAX_KB/1024/1024" | bc -l 2>/dev/null | sed 's/^\./0./')
    [ -n "$BUILD_PEAK_GB" ] && echo "Build peak 从 csv 回退: ${BUILD_PEAK_GB} GB" | tee -a "$LOG_FILE"
  else
    echo "Build peak 仍为 0，csv 前 5 行:" | tee -a "$LOG_FILE"
    head -5 "$RESULT_DIR/probfuzz_build" 2>/dev/null | tee -a "$LOG_FILE" || true
  fi
fi

echo "=== [3/4] Run 阶段（./probfuzz.py 1）— 进程树峰值监控 ===" | tee -a "$LOG_FILE"

# 确保 python2/python3 有 numpy 和 antlr4（run 先试 python2，antlr 生成的是 Py2 代码）
for py in python2 python3 python; do
  command -v "$py" >/dev/null 2>&1 || continue

  if ! "$py" -c "import numpy" 2>/dev/null; then
    echo "为 $py 安装 numpy/six..." | tee -a "$LOG_FILE"
    "$py" -m pip install --user numpy six 2>&1 | tail -3 | tee -a "$LOG_FILE" || true
  fi

  # antlr jar 4.7.1 生成的代码需 antlr4-runtime 4.7.x（4.13 会 ATN 版本不兼容）
  if "$py" -c "import sys; exit(0 if sys.version_info[0]==2 else 1)" 2>/dev/null; then
    echo "为 python2 安装 antlr4-python2-runtime==4.7.2（匹配 jar 4.7.1）..." | tee -a "$LOG_FILE"
    "$py" -m pip install --user "antlr4-python2-runtime==4.7.2" 2>&1 | tail -2 | tee -a "$LOG_FILE" || true
  elif "$py" -c "import sys; exit(0 if sys.version_info[0]==3 else 1)" 2>/dev/null; then
    "$py" -c "import antlr4" 2>/dev/null || {
      echo "为 python3 安装 antlr4-python3-runtime==4.7.2..." | tee -a "$LOG_FILE"
      "$py" -m pip install --user "antlr4-python3-runtime==4.7.2" 2>&1 | tail -2 | tee -a "$LOG_FILE" || true
    }
  fi
done

# 若 antlr 未生成（install.sh 里 run.sh 因无 java 失败），这里用 conda 的 java 再生成一次
JAVA_CMD="$(command -v java 2>/dev/null || true)"
ANTLR_DIR="$WORK_DIR/language/antlr"
if [ -d "$ANTLR_DIR" ] && [ -n "$JAVA_CMD" ] && [ ! -f "$ANTLR_DIR/TemplateLexer.py" ]; then
  echo "用 $JAVA_CMD 生成 antlr 解析器..." | tee -a "$LOG_FILE"
  ( cd "$ANTLR_DIR" \
    && wget -q https://www.antlr.org/download/antlr-4.7.1-complete.jar -O antlr-4.7.1-complete.jar 2>/dev/null \
    && "$JAVA_CMD" -Xmx500M -cp ".:./antlr-4.7.1-complete.jar:$CLASSPATH" org.antlr.v4.Tool -Dlanguage=Python2 -visitor Template.g4 2>/dev/null \
    && touch __init__.py 2>/dev/null ) || true
fi

RUN_START=$(date +%s)
RUN_EXIT=1
set +e

# antlr 生成的是 Python2 代码，优先用 python2 跑
for py in python2 python3 python; do
  command -v "$py" >/dev/null 2>&1 || continue
  ( cd "$WORK_DIR" && PYTHONPATH="$WORK_DIR/language/antlr:$WORK_DIR/language:$PYTHONPATH" "$py" ./probfuzz.py 1 2>&1 ) &
  RUN_PID=$!
  TARGET_PID="$RUN_PID"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    CHILD_PID=$(ps -eo ppid,pid,cmd 2>/dev/null | awk -v p="$RUN_PID" '$1+0==p+0 && $3 ~ /python/ {print $2; exit}')
    if [ -n "$CHILD_PID" ]; then
      TARGET_PID="$CHILD_PID"
      break
    fi
    kill -0 "$RUN_PID" 2>/dev/null || break
    sleep 0.1
  done
  $MONITOR "$TARGET_PID" "$RESULT_DIR/probfuzz_run" &
  MON_PID=$!
  wait $RUN_PID 2>/dev/null
  RUN_EXIT=$?
  wait $MON_PID 2>/dev/null || true
  [ "$RUN_EXIT" = "0" ] && break
done

set -e
RUN_END=$(date +%s)
RUN_RUNTIME=$((RUN_END - RUN_START))

RUN_PEAK_GB=0
if [ -f "$RESULT_DIR/probfuzz_run.peaks" ]; then
  RUN_PEAK_GB=$(grep '^PEAK_RAM_GB=' "$RESULT_DIR/probfuzz_run.peaks" | cut -d= -f2)
  [[ "$RUN_PEAK_GB" = .* ]] && RUN_PEAK_GB="0$RUN_PEAK_GB"
fi
# peaks 为 0 但 run 成功且 monitor 写了 csv，从 csv 取最大 RSS 作为回退
if [ -f "$RESULT_DIR/probfuzz_run" ] && { [ "${RUN_PEAK_GB:-0}" = "0" ] || [ "${RUN_PEAK_GB:-0}" = "0.0000" ]; }; then
  MAX_KB=$(awk -F, 'NR>1 && $2+0>m {m=$2+0} END {print m+0}' "$RESULT_DIR/probfuzz_run" 2>/dev/null)
  if [ -n "$MAX_KB" ] && [ "$MAX_KB" -gt 0 ] 2>/dev/null; then
    RUN_PEAK_GB=$(echo "scale=4; $MAX_KB/1024/1024" | bc -l 2>/dev/null | sed 's/^\./0./')
    [ -n "$RUN_PEAK_GB" ] && echo "Run peak 从 csv 回退: ${RUN_PEAK_GB} GB" | tee -a "$LOG_FILE"
  else
    echo "Run peak 仍为 0，csv 前 5 行:" | tee -a "$LOG_FILE"
    head -5 "$RESULT_DIR/probfuzz_run" 2>/dev/null | tee -a "$LOG_FILE" || true
  fi
fi

# 磁盘：工作目录（clone+output 若存在都在里面）
DISK_KB=$(du -sk "$WORK_DIR" 2>/dev/null | awk '{print $1}')
DISK_GB=$(echo "scale=4; $DISK_KB/1024/1024" | bc -l 2>/dev/null | sed 's/^\./0./' || echo "0")
[ -z "$DISK_GB" ] && DISK_GB=0

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
[ "${MIN_RUN_RAM:-0}" -gt "${MIN_RAM:-0}" ] && MIN_RAM=$MIN_RUN_RAM
MIN_DISK=$(round_disk "$DISK_GB")

echo "=== [4/4] 输出 result/probfuzz.json ===" | tee -a "$LOG_FILE"
cat > "$RESULT_DIR/probfuzz.json" << EOF
{
  "name": "probfuzz",
  "url": "https://github.com/uiuc-arc/probfuzz",
  "mvw": {
    "mvw_command": "sudo ./install.sh && ./probfuzz.py 1",
    "build_command": "install.sh if apt-get+sudo, else pip install --user deps + antlr generation",
    "run_command": "./probfuzz.py 1",
    "input_scale": "1 program per PPS (Stan, Edward, Pyro), config max_threads=1",
    "success_criteria": "exit code 0, output dir created with summary"
  },
  "environment": {
    "os": "Linux",
    "python": "python2 preferred for generated antlr code, then python3; script applies Queue-compat patch for Py3 and ensures numpy/antlr4 (pip install --user if missing).",
    "methodology": "one-pass profiling; process-tree RSS peak (monitor_tree.sh), whole tree not single process; MVW actually run; multi-thread peaks captured by tree monitor."
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
    "cpu_utilization_summary": "build: deps/antlr; run: Stan/Edward/Pyro inference"
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

echo "Done. Build peak RAM: ${BUILD_PEAK_GB} GB, Run peak RAM: ${RUN_PEAK_GB} GB, Disk: ${DISK_GB} GB" | tee -a "$LOG_FILE"
echo "Result: $RESULT_DIR/probfuzz.json"