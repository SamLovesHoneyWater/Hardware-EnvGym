#!/usr/bin/env python3
"""
Measure grpc-go build and test peak RSS (process tree) and disk, write result/grpc_grpc-go_peaks.txt.
Requires: go in PATH, git. Run from Label dir or set LABEL.
"""
import os
import subprocess
import time
import threading

LABEL = os.environ.get("LABEL", "/home/cc/Label")
REPO = os.path.join(LABEL, "grpc-go-measure")
OUT = os.path.join(LABEL, "result", "grpc_grpc-go_peaks.txt")
PATH = os.path.join(LABEL, "tools", "go", "bin") + os.pathsep + os.environ.get("PATH", "")

def env():
    return {**os.environ, "PATH": PATH}

def tree_rss_kb(root_pid):
    """Sum RSS (KB) of root_pid and all descendants. Uses /proc and ps."""
    try:
        out = subprocess.check_output(
            ["ps", "-eo", "pid,ppid,rss"],
            env=env(), text=True, timeout=5
        )
    except Exception:
        return 0
    ppid_map = {}
    rss_map = {}
    for line in out.strip().split("\n")[1:]:
        parts = line.split()
        if len(parts) >= 3 and parts[0].isdigit():
            pid, ppid, rss = int(parts[0]), parts[1], int(parts[2]) if parts[2].isdigit() else 0
            ppid_map[pid] = int(ppid) if ppid.isdigit() else None
            rss_map[pid] = rss
    if root_pid not in rss_map:
        return 0
    pids = [root_pid]
    added = True
    while added:
        added = False
        for pid, ppid in ppid_map.items():
            if ppid is not None and ppid in pids and pid not in pids:
                pids.append(pid)
                added = True
    return sum(rss_map.get(p, 0) for p in pids)

def run_with_sampling(cmd, name, sample_interval=0.5):
    proc = subprocess.Popen(cmd, cwd=REPO, env=env(), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    max_kb = 0
    try:
        while proc.poll() is None:
            kb = tree_rss_kb(proc.pid)
            if kb > max_kb:
                max_kb = kb
            time.sleep(sample_interval)
    finally:
        if proc.poll() is None:
            proc.terminate()
            proc.wait(timeout=10)
    return max_kb

def main():
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    if not os.path.isdir(os.path.join(REPO, ".git")):
        if os.path.isdir(REPO):
            import shutil
            shutil.rmtree(REPO, ignore_errors=True)
        subprocess.check_call(
            ["git", "clone", "--depth", "1", "https://github.com/grpc/grpc-go.git", REPO],
            env=env(), timeout=120
        )
    build_kb = run_with_sampling(["go", "build", "./..."], "build")
    test_kb = run_with_sampling(["go", "test", "-short", "./..."], "test")
    repo_kb = int(subprocess.check_output(["du", "-s", REPO], text=True).split()[0])
    try:
        cache = subprocess.check_output(["go", "env", "GOMODCACHE"], cwd=REPO, env=env(), text=True).strip()
        cache_kb = int(subprocess.check_output(["du", "-s", cache], text=True).split()[0])
    except Exception:
        cache_kb = 0
    disk_kb = repo_kb + cache_kb
    with open(OUT, "w") as f:
        f.write(f"build_peak_rss_kb={build_kb}\ntest_peak_rss_kb={test_kb}\npeak_disk_kb={disk_kb}\n")
    print(f"build_peak_rss_kb={build_kb}", f"test_peak_rss_kb={test_kb}", f"peak_disk_kb={disk_kb}")
    print(f"Wrote {OUT}")

if __name__ == "__main__":
    main()
