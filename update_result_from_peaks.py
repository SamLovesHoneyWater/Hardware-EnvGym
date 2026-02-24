#!/usr/bin/env python3
"""Update a result JSON from a peaks file. Usage: update_result_from_peaks.py <peaks.txt> <result.json>"""
import json
import re
import sys

def parse_peaks(path):
    d = {}
    with open(path) as f:
        for line in f:
            m = re.match(r"(\w+)=(.+)", line.strip())
            if m:
                key, val = m.group(1), m.group(2).strip()
                try:
                    d[key] = int(val)
                except ValueError:
                    try:
                        d[key] = float(val)
                    except ValueError:
                        pass
    return d.get("build_peak_rss_kb", 0), d.get("test_peak_rss_kb", 0), d.get("peak_disk_kb", 0), d

def round_up_sku(val, skus):
    for s in skus:
        if val <= s:
            return s
    return skus[-1]

def main():
    peaks_path = sys.argv[1]
    json_path = sys.argv[2]
    build_kb, test_kb, disk_kb, peaks_dict = parse_peaks(peaks_path)
    build_ram_gb = build_kb / (1024 * 1024)
    test_ram_gb = test_kb / (1024 * 1024)
    disk_gb = disk_kb / (1024 * 1024)
    peak_ram_gb = max(build_ram_gb, test_ram_gb)
    min_ram_gb = round_up_sku(peak_ram_gb, [2, 4, 8, 16])
    min_disk_gb = round_up_sku(disk_gb, [1, 2, 4, 8])
    with open(json_path) as f:
        j = json.load(f)
    j["peaks_observed"]["build_peak_ram_gb"] = round(build_ram_gb, 2)
    j["peaks_observed"]["run_peak_ram_gb"] = round(test_ram_gb, 2)
    j["peaks_observed"]["peak_disk_gb"] = round(disk_gb, 2)
    if "build_runtime_seconds" in peaks_dict and "build_runtime_seconds" in j["peaks_observed"]:
        j["peaks_observed"]["build_runtime_seconds"] = round(peaks_dict["build_runtime_seconds"], 2)
    if "run_runtime_seconds" in peaks_dict and "run_runtime_seconds" in j["peaks_observed"]:
        j["peaks_observed"]["run_runtime_seconds"] = round(peaks_dict["run_runtime_seconds"], 2)
    j["environment"]["methodology"] = (
        "tutorial.md one-pass profiling; peaks from process-tree measurement (measure_* script), "
        "RSS sampled every 0.5s for root and all child processes."
    )
    j["min_hardware"]["build_min_spec"]["min_ram_gb"] = min_ram_gb
    j["min_hardware"]["build_min_spec"]["min_disk_gb"] = min_disk_gb
    j["min_hardware"]["run_min_spec"]["min_ram_gb"] = min_ram_gb
    j["min_hardware"]["run_min_spec"]["min_disk_gb"] = min_disk_gb
    j["margins_used"] = "none"
    j["min_hardware"]["summary"] = (
        f"2 vCPU / {min_ram_gb} GB RAM / {min_disk_gb} GB disk, no GPU. "
        f"Raw peaks (rounded up to SKU): build {build_ram_gb:.2f} GB RAM, run {test_ram_gb:.2f} GB RAM, disk {disk_gb:.2f} GB."
    )
    with open(json_path, "w") as f:
        json.dump(j, f, indent=2, ensure_ascii=False)
    print(f"Updated {json_path}")

if __name__ == "__main__":
    main()
