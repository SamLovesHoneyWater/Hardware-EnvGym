#!/usr/bin/env python3
import csv
import json
import math
from collections import Counter
from pathlib import Path

import matplotlib.pyplot as plt


BASE_DIR = Path("/home/cc/Label")
RESULT_DIR = BASE_DIR / "result"
OUT_DIR = BASE_DIR / "result_analysis"


def to_float(value, default=0.0):
    try:
        if value is None:
            return default
        return float(value)
    except (TypeError, ValueError):
        return default


def to_int(value, default=0):
    try:
        if value is None:
            return default
        return int(value)
    except (TypeError, ValueError):
        return default


def percentile(sorted_values, q):
    if not sorted_values:
        return 0.0
    if len(sorted_values) == 1:
        return float(sorted_values[0])
    pos = (len(sorted_values) - 1) * q
    left = int(math.floor(pos))
    right = int(math.ceil(pos))
    if left == right:
        return float(sorted_values[left])
    weight = pos - left
    return float(sorted_values[left] * (1 - weight) + sorted_values[right] * weight)


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    files = sorted(RESULT_DIR.glob("*.json"))
    rows = []

    for path in files:
        with path.open("r", encoding="utf-8") as f:
            data = json.load(f)
        peaks = data.get("peaks_observed", {})
        mins = data.get("min_hardware", {})
        build_min = mins.get("build_min_spec", {})
        run_min = mins.get("run_min_spec", {})

        row = {
            "name": data.get("name", path.stem),
            "url": data.get("url", ""),
            "build_peak_ram_gb": to_float(peaks.get("build_peak_ram_gb")),
            "run_peak_ram_gb": to_float(peaks.get("run_peak_ram_gb")),
            "peak_disk_gb": to_float(peaks.get("peak_disk_gb")),
            "build_runtime_seconds": to_float(peaks.get("build_runtime_seconds")),
            "run_runtime_seconds": to_float(peaks.get("run_runtime_seconds")),
            "build_min_ram_gb": to_int(build_min.get("min_ram_gb")),
            "run_min_ram_gb": to_int(run_min.get("min_ram_gb")),
            "build_min_disk_gb": to_int(build_min.get("min_disk_gb")),
            "run_min_disk_gb": to_int(run_min.get("min_disk_gb")),
            "build_min_vcpu": to_int(build_min.get("min_vcpu")),
            "run_min_vcpu": to_int(run_min.get("min_vcpu")),
        }
        rows.append(row)

    if not rows:
        raise SystemExit("No result json files found.")

    csv_path = OUT_DIR / "repo_resource_table.csv"
    with csv_path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)

    build_ram = sorted([r["build_peak_ram_gb"] for r in rows])
    run_ram = sorted([r["run_peak_ram_gb"] for r in rows])
    disk = sorted([r["peak_disk_gb"] for r in rows])
    build_rt = sorted([r["build_runtime_seconds"] for r in rows])
    run_rt = sorted([r["run_runtime_seconds"] for r in rows])

    summary = {
        "repo_count": len(rows),
        "build_peak_ram_gb": {
            "min": min(build_ram),
            "p50": percentile(build_ram, 0.50),
            "p90": percentile(build_ram, 0.90),
            "max": max(build_ram),
        },
        "run_peak_ram_gb": {
            "min": min(run_ram),
            "p50": percentile(run_ram, 0.50),
            "p90": percentile(run_ram, 0.90),
            "max": max(run_ram),
        },
        "peak_disk_gb": {
            "min": min(disk),
            "p50": percentile(disk, 0.50),
            "p90": percentile(disk, 0.90),
            "max": max(disk),
        },
        "build_runtime_seconds": {
            "min": min(build_rt),
            "p50": percentile(build_rt, 0.50),
            "p90": percentile(build_rt, 0.90),
            "max": max(build_rt),
        },
        "run_runtime_seconds": {
            "min": min(run_rt),
            "p50": percentile(run_rt, 0.50),
            "p90": percentile(run_rt, 0.90),
            "max": max(run_rt),
        },
    }

    with (OUT_DIR / "summary.json").open("w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2)

    # Plot 1: histograms
    fig, axes = plt.subplots(1, 3, figsize=(15, 4.5))
    axes[0].hist(build_ram, bins=10, color="#4e79a7", edgecolor="white")
    axes[0].set_title("Build Peak RAM (GB)")
    axes[0].set_xlabel("GB")
    axes[0].set_ylabel("Repo count")

    axes[1].hist(run_ram, bins=10, color="#f28e2b", edgecolor="white")
    axes[1].set_title("Run Peak RAM (GB)")
    axes[1].set_xlabel("GB")
    axes[1].set_ylabel("Repo count")

    axes[2].hist(disk, bins=10, color="#59a14f", edgecolor="white")
    axes[2].set_title("Peak Disk (GB)")
    axes[2].set_xlabel("GB")
    axes[2].set_ylabel("Repo count")

    fig.suptitle(f"Resource Usage Distribution Across {len(rows)} Repositories", fontsize=13)
    fig.tight_layout()
    fig.savefig(OUT_DIR / "resource_histograms.png", dpi=160)
    plt.close(fig)

    # Plot 2: min spec distribution
    run_min_ram_counts = Counter([r["run_min_ram_gb"] for r in rows])
    run_min_disk_counts = Counter([r["run_min_disk_gb"] for r in rows])
    run_min_vcpu_counts = Counter([r["run_min_vcpu"] for r in rows])

    fig, axes = plt.subplots(1, 3, figsize=(15, 4.5))

    x = sorted(run_min_ram_counts.keys())
    axes[0].bar([str(v) for v in x], [run_min_ram_counts[v] for v in x], color="#e15759")
    axes[0].set_title("Run Min RAM SKU Distribution")
    axes[0].set_xlabel("RAM SKU (GB)")
    axes[0].set_ylabel("Repo count")

    x = sorted(run_min_disk_counts.keys())
    axes[1].bar([str(v) for v in x], [run_min_disk_counts[v] for v in x], color="#76b7b2")
    axes[1].set_title("Run Min Disk SKU Distribution")
    axes[1].set_xlabel("Disk SKU (GB)")
    axes[1].set_ylabel("Repo count")

    x = sorted(run_min_vcpu_counts.keys())
    axes[2].bar([str(v) for v in x], [run_min_vcpu_counts[v] for v in x], color="#edc948")
    axes[2].set_title("Run Min vCPU Distribution")
    axes[2].set_xlabel("vCPU")
    axes[2].set_ylabel("Repo count")

    fig.suptitle("Minimum Run Spec Distribution", fontsize=13)
    fig.tight_layout()
    fig.savefig(OUT_DIR / "min_spec_distribution.png", dpi=160)
    plt.close(fig)

    # Plot 3: runtime vs run RAM
    fig, ax = plt.subplots(figsize=(7, 5))
    ax.scatter(
        [r["run_peak_ram_gb"] for r in rows],
        [r["run_runtime_seconds"] for r in rows],
        alpha=0.8,
        color="#af7aa1",
    )
    ax.set_title("Run Runtime vs Run Peak RAM")
    ax.set_xlabel("Run Peak RAM (GB)")
    ax.set_ylabel("Run Runtime (seconds)")
    ax.grid(alpha=0.25)
    fig.tight_layout()
    fig.savefig(OUT_DIR / "runtime_vs_ram_scatter.png", dpi=160)
    plt.close(fig)

    md = OUT_DIR / "README.md"
    with md.open("w", encoding="utf-8") as f:
        f.write("# Repository Resource Analysis\n\n")
        f.write(f"- Total repositories analyzed: **{len(rows)}**\n")
        f.write(f"- Source directory: `{RESULT_DIR}`\n\n")
        f.write("## Output files\n\n")
        f.write("- `repo_resource_table.csv`\n")
        f.write("- `summary.json`\n")
        f.write("- `resource_histograms.png`\n")
        f.write("- `min_spec_distribution.png`\n")
        f.write("- `runtime_vs_ram_scatter.png`\n")


if __name__ == "__main__":
    main()
