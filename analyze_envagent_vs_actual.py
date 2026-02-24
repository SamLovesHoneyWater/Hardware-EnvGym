#!/usr/bin/env python3
import json
import re
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np


ROOT = Path("/home/cc")
HARDWARE_JSON = ROOT / "Label/hardware.json"
RESULT_DIR = ROOT / "Label/result"
LOG_DIR = ROOT / "EnvAgent-plus/logs"
OUT_DIR = ROOT / "Label/result_analysis/envagent_compare"


def parse_float_like(text):
    if text is None:
        return 0.0
    t = text.strip().lower()
    if t in {"none", "n/a", "na", ""}:
        return 0.0
    try:
        return float(t)
    except ValueError:
        m = re.search(r"[-+]?\d*\.?\d+", t)
        return float(m.group(0)) if m else 0.0


def extract_log_fields(log_text):
    repo_url = None
    m = re.search(r'--repo\s+"([^"]+)"', log_text)
    if m:
        repo_url = m.group(1).strip()

    cpu = re.search(r"CPU:\s*([^\n\r]+?)\s*cores", log_text)
    ram = re.search(r"RAM:\s*([^\n\r]+?)\s*GB", log_text)
    disk = re.search(r"Disk:\s*([^\n\r]+?)\s*GB", log_text)
    gpu = re.search(r"GPU:\s*([^\n\r]+)", log_text)
    node_type = re.search(r"Target node type:\s*([^\n\r]+)", log_text)
    exit_code = re.search(r"End:\s+.*\(exit=(\d+),", log_text)

    pred_cpu = parse_float_like(cpu.group(1)) if cpu else 0.0
    pred_ram = parse_float_like(ram.group(1)) if ram else 0.0
    pred_disk = parse_float_like(disk.group(1)) if disk else 0.0
    pred_gpu = 1.0 if gpu and "required" in gpu.group(1).lower() else 0.0

    return {
        "repo_url": repo_url,
        "pred_cpu": pred_cpu,
        "pred_ram": pred_ram,
        "pred_disk": pred_disk,
        "pred_gpu": pred_gpu,
        "node_type": node_type.group(1).strip() if node_type else None,
        "exit_code": int(exit_code.group(1)) if exit_code else -1,
    }


def latest_log_key(path: Path):
    # filename example: 20251216_092119_zeromicro_go-zero.log
    parts = path.name.split("_")
    if len(parts) >= 2 and parts[0].isdigit() and parts[1].isdigit():
        return parts[0] + parts[1]
    return ""


def load_latest_logs_for_repos(repo_urls):
    best = {}
    for p in LOG_DIR.glob("*.log"):
        text = p.read_text(encoding="utf-8", errors="ignore")
        info = extract_log_fields(text)
        url = info["repo_url"]
        if not url or url not in repo_urls:
            continue
        key = latest_log_key(p)
        if url not in best or key > best[url]["_key"]:
            info["_key"] = key
            info["_path"] = str(p)
            best[url] = info
    return best


def load_actual_need(repo_name):
    result_path = RESULT_DIR / f"{repo_name}.json"
    if not result_path.exists():
        return {"cpu": 0.0, "ram": 0.0, "disk": 0.0, "gpu": 0.0}
    data = json.loads(result_path.read_text(encoding="utf-8"))
    run_min = data.get("min_hardware", {}).get("run_min_spec", {})
    requires_gpu = bool(data.get("static_triage", {}).get("requires_gpu", False))
    return {
        "cpu": float(run_min.get("min_vcpu", 0) or 0),
        "ram": float(run_min.get("min_ram_gb", 0) or 0),
        "disk": float(run_min.get("min_disk_gb", 0) or 0),
        "gpu": 1.0 if requires_gpu else 0.0,
    }


def plot_resource(repos, pred, need, reserved, ylabel, title, out_path):
    # Sort by actual required (ascending), then by repo name.
    order = sorted(range(len(repos)), key=lambda i: (need[i], repos[i]))
    repos = [repos[i] for i in order]
    pred = [pred[i] for i in order]
    need = [need[i] for i in order]
    reserved = [reserved[i] for i in order]

    x = np.arange(len(repos))
    fig, ax = plt.subplots(figsize=(max(12, len(repos) * 0.42), 5.2))
    ax.plot(x, pred, marker="o", linewidth=1.8, markersize=3.5, label="Agent Predicted", color="#4e79a7")
    ax.plot(x, need, marker="o", linewidth=1.8, markersize=3.5, label="Actual Required", color="#f28e2b")
    ax.plot(x, reserved, marker="o", linewidth=1.8, markersize=3.5, label="Actually Reserved", color="#59a14f")
    ax.set_title(title)
    ax.set_ylabel(ylabel)
    ax.set_xlabel("Repositories (sorted by actual required ascending)")
    ax.set_xticks(x)
    ax.set_xticklabels(repos, rotation=60, ha="right", fontsize=8)
    ax.grid(axis="y", alpha=0.25)
    ax.legend()
    fig.tight_layout()
    fig.savefig(out_path, dpi=170)
    plt.close(fig)


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    hw = json.loads(HARDWARE_JSON.read_text(encoding="utf-8"))
    repo_urls = {x["url"] for x in hw}
    name_by_url = {x["url"]: x["name"] for x in hw}

    latest_logs = load_latest_logs_for_repos(repo_urls)

    rows = []
    for url in sorted(name_by_url, key=lambda u: name_by_url[u]):
        name = name_by_url[url]
        actual = load_actual_need(name)
        log = latest_logs.get(url, {})
        pred_cpu = float(log.get("pred_cpu", 0.0) or 0.0)
        pred_ram = float(log.get("pred_ram", 0.0) or 0.0)
        pred_disk = float(log.get("pred_disk", 0.0) or 0.0)
        pred_gpu = float(log.get("pred_gpu", 0.0) or 0.0)
        exit_code = int(log.get("exit_code", -1))
        # Latest matching runs are failed in this dataset; failed reservation = 0 acquired resources.
        reserved_cpu = 0.0 if exit_code != 0 else np.nan
        reserved_ram = 0.0 if exit_code != 0 else np.nan
        reserved_disk = 0.0 if exit_code != 0 else np.nan
        reserved_gpu = 0.0 if exit_code != 0 else np.nan

        rows.append(
            {
                "repo": name,
                "url": url,
                "log_path": log.get("_path"),
                "log_exit_code": exit_code,
                "pred_cpu": pred_cpu,
                "pred_ram": pred_ram,
                "pred_disk": pred_disk,
                "pred_gpu": pred_gpu,
                "need_cpu": actual["cpu"],
                "need_ram": actual["ram"],
                "need_disk": actual["disk"],
                "need_gpu": actual["gpu"],
                "reserved_cpu": reserved_cpu,
                "reserved_ram": reserved_ram,
                "reserved_disk": reserved_disk,
                "reserved_gpu": reserved_gpu,
            }
        )

    # Replace NaN (successful but unknown numeric reservation) with 0 for plotting; keep note in README.
    def num(v):
        return 0.0 if (isinstance(v, float) and np.isnan(v)) else float(v)

    repos = [r["repo"] for r in rows]
    pred_cpu = [num(r["pred_cpu"]) for r in rows]
    need_cpu = [num(r["need_cpu"]) for r in rows]
    res_cpu = [num(r["reserved_cpu"]) for r in rows]

    pred_ram = [num(r["pred_ram"]) for r in rows]
    need_ram = [num(r["need_ram"]) for r in rows]
    res_ram = [num(r["reserved_ram"]) for r in rows]

    pred_disk = [num(r["pred_disk"]) for r in rows]
    need_disk = [num(r["need_disk"]) for r in rows]
    res_disk = [num(r["reserved_disk"]) for r in rows]

    pred_gpu = [num(r["pred_gpu"]) for r in rows]
    need_gpu = [num(r["need_gpu"]) for r in rows]
    res_gpu = [num(r["reserved_gpu"]) for r in rows]

    plot_resource(
        repos,
        pred_cpu,
        need_cpu,
        res_cpu,
        ylabel="vCPU / cores",
        title="CPU: Predicted vs Required vs Reserved",
        out_path=OUT_DIR / "cpu_comparison.png",
    )
    plot_resource(
        repos,
        pred_ram,
        need_ram,
        res_ram,
        ylabel="GB",
        title="RAM: Predicted vs Required vs Reserved",
        out_path=OUT_DIR / "ram_comparison.png",
    )
    plot_resource(
        repos,
        pred_disk,
        need_disk,
        res_disk,
        ylabel="GB",
        title="Disk: Predicted vs Required vs Reserved",
        out_path=OUT_DIR / "disk_comparison.png",
    )
    plot_resource(
        repos,
        pred_gpu,
        need_gpu,
        res_gpu,
        ylabel="GPU count (1=required/present)",
        title="GPU: Predicted vs Required vs Reserved",
        out_path=OUT_DIR / "gpu_comparison.png",
    )

    reserved_sufficient = 0
    predicted_sufficient = 0
    for r in rows:
        if (
            num(r["reserved_cpu"]) >= num(r["need_cpu"])
            and num(r["reserved_ram"]) >= num(r["need_ram"])
            and num(r["reserved_disk"]) >= num(r["need_disk"])
            and num(r["reserved_gpu"]) >= num(r["need_gpu"])
        ):
            reserved_sufficient += 1
        if (
            num(r["pred_cpu"]) >= num(r["need_cpu"])
            and num(r["pred_ram"]) >= num(r["need_ram"])
            and num(r["pred_disk"]) >= num(r["need_disk"])
            and num(r["pred_gpu"]) >= num(r["need_gpu"])
        ):
            predicted_sufficient += 1
    reserved_ratio = reserved_sufficient / len(rows) if rows else 0.0
    predicted_ratio = predicted_sufficient / len(rows) if rows else 0.0

    # Output data table
    import csv

    with (OUT_DIR / "envagent_vs_actual_table.csv").open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)

    summary = {
        "repo_count": len(rows),
        "latest_log_count_found": len(latest_logs),
        "actual_reserved_sufficient_count": reserved_sufficient,
        "actual_reserved_sufficient_ratio": reserved_ratio,
        "ai_predicted_sufficient_count": predicted_sufficient,
        "ai_predicted_sufficient_ratio": predicted_ratio,
        "note": "Reserved resources are treated as 0 when latest run failed (exit != 0).",
    }

    def avg_redundancy(rows_data, prefix):
        out = {}
        for rname in ("cpu", "ram", "disk", "gpu"):
            vals = []
            for item in rows_data:
                need = num(item[f"need_{rname}"])
                have = num(item[f"{prefix}_{rname}"])
                if need > 0:
                    vals.append((have - need) / need * 100.0)
            out[rname] = (sum(vals) / len(vals)) if vals else None
        return out

    summary["average_redundancy_percent"] = {
        "reserved": avg_redundancy(rows, "reserved"),
        "predicted": avg_redundancy(rows, "pred"),
    }
    (OUT_DIR / "sufficiency_summary.json").write_text(
        json.dumps(summary, indent=2), encoding="utf-8"
    )

    (OUT_DIR / "README.md").write_text(
        "\n".join(
            [
                "# EnvAgent Resource Comparison",
                "",
                "- Metrics compared: CPU, RAM, Disk, GPU",
                "- Series in each plot: Agent Predicted, Actual Required, Actually Reserved",
                "- Repo count: {}".format(len(rows)),
                "- Actual reserved sufficient ratio (all 4 resources): {:.4f} ({}/{})".format(
                    reserved_ratio, reserved_sufficient, len(rows)
                ),
                "- AI predicted sufficient ratio (all 4 resources): {:.4f} ({}/{})".format(
                    predicted_ratio, predicted_sufficient, len(rows)
                ),
                "- Average reserved redundancy (%): {}".format(summary["average_redundancy_percent"]["reserved"]),
                "- Average predicted redundancy (%): {}".format(summary["average_redundancy_percent"]["predicted"]),
                "",
                "## Files",
                "- envagent_vs_actual_table.csv",
                "- sufficiency_summary.json",
                "- cpu_comparison.png",
                "- ram_comparison.png",
                "- disk_comparison.png",
                "- gpu_comparison.png",
            ]
        ),
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
