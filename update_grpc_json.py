#!/usr/bin/env python3
"""读取 measure_grpc_ram.sh 生成的 peaks 文件，更新 grpc_grpc-go.json 的 peaks 与 min_hardware。"""
import json
import re
import sys

def parse_peaks(path):
    d = {}
    with open(path) as f:
        for line in f:
            m = re.match(r'(\w+)=(.+)', line.strip())
            if m:
                d[m.group(1)] = int(m.group(2).strip())
    return d.get('build_peak_rss_kb', 0), d.get('test_peak_rss_kb', 0), d.get('peak_disk_kb', 0)

def round_up_sku(val, skus):
    for s in skus:
        if val <= s:
            return s
    return skus[-1]

def main():
    peaks_path = sys.argv[1]
    json_path = sys.argv[2]
    build_kb, test_kb, disk_kb = parse_peaks(peaks_path)
    build_ram_gb = build_kb / (1024 * 1024)
    test_ram_gb = test_kb / (1024 * 1024)
    disk_gb = disk_kb / (1024 * 1024)
    peak_ram_gb = max(build_ram_gb, test_ram_gb)
    min_ram_raw = peak_ram_gb * 1.3 + 1.0
    min_disk_raw = disk_gb * 1.3
    min_ram_gb = round_up_sku(min_ram_raw, [2, 4, 8, 16])
    min_disk_gb = round_up_sku(min_disk_raw, [1, 2, 4, 8])
    with open(json_path) as f:
        j = json.load(f)
    j["peaks_observed"]["build_peak_ram_gb"] = round(build_ram_gb, 2)
    j["peaks_observed"]["run_peak_ram_gb"] = round(test_ram_gb, 2)
    j["peaks_observed"]["peak_disk_gb"] = round(disk_gb, 2)
    j["environment"]["methodology"] = (
        "tutorial.md one-pass profiling; peaks_observed from process-tree measurement (measure_grpc_ram.sh), "
        "sampling sum RSS of go and all child processes every 0.5s, taking the maximum."
    )
    j["min_hardware"]["build_min_spec"]["min_ram_gb"] = min_ram_gb
    j["min_hardware"]["build_min_spec"]["min_disk_gb"] = min_disk_gb
    j["min_hardware"]["run_min_spec"]["min_ram_gb"] = min_ram_gb
    j["min_hardware"]["run_min_spec"]["min_disk_gb"] = min_disk_gb
    j["min_hardware"]["summary"] = (
        f"2 vCPU / {min_ram_gb} GB RAM / {min_disk_gb} GB disk, no GPU. "
        f"MVW: go build ./... and go test -short ./... "
        f"Process-tree measured peaks: build {build_ram_gb:.2f} GB RAM, run {test_ram_gb:.2f} GB RAM, disk {disk_gb:.2f} GB."
    )
    with open(json_path, "w") as f:
        json.dump(j, f, indent=2, ensure_ascii=False)

if __name__ == "__main__":
    main()
