#!/usr/bin/env python3
import csv
import json
import re
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np


ROOT = Path("/home/cc")
HARDWARE_JSON = ROOT / "Label/hardware.json"
RESULT_DIR = ROOT / "Label/result"
LOG_DIR = ROOT / "logs_kvm"
OUT_DIR = ROOT / "Label/result_analysis/envagent_compare_kvm"


# Approximate reserved capacities by actual node type.
# Values are used for comparison trends, not hardware benchmarking.
NODE_TYPE_CAPACITY = {
    "compute_cascadelake": {"cpu": 48.0, "ram": 192.0, "disk": 240.0, "gpu": 0.0},
    "compute_cascadelake_r": {"cpu": 48.0, "ram": 192.0, "disk": 240.0, "gpu": 0.0},
    "compute_icelake_r650": {"cpu": 64.0, "ram": 256.0, "disk": 480.0, "gpu": 0.0},
    "compute_icelake_r750": {"cpu": 64.0, "ram": 512.0, "disk": 480.0, "gpu": 0.0},
    "compute_skylake": {"cpu": 48.0, "ram": 192.0, "disk": 240.0, "gpu": 0.0},
    "gpu_m40": {"cpu": 32.0, "ram": 256.0, "disk": 240.0, "gpu": 2.0},
}


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
    m = re.search(r'--repo\s+"([^"]+)"', log_text)
    repo_url = m.group(1).strip() if m else None

    cpu = re.search(r"CPU:\s*([^\n\r]+?)\s*cores", log_text)
    ram = re.search(r"RAM:\s*([^\n\r]+?)\s*GB", log_text)
    disk = re.search(r"Disk:\s*([^\n\r]+?)\s*GB", log_text)
    gpu = re.search(r"GPU:\s*([^\n\r]+)", log_text)
    target = re.search(r"Target node type:\s*([^\n\r]+)", log_text)
    actual = re.search(r"Node Type \(actual\):\s*([^\n\r]+)", log_text)
    exit_code = re.search(r"End:\s+.*\(exit=(\d+),", log_text)

    # For KVM fallback, parse selected VM size if present.
    kvm_cpu_ram = re.search(r"Selecting KVM flavor \(CPU:\s*([0-9]+),\s*RAM:\s*([0-9]+)GB\)", log_text)
    flavor_name = re.search(r"Selected flavor:\s*([^\n\r]+)", log_text)

    return {
        "repo_url": repo_url,
        "pred_cpu": parse_float_like(cpu.group(1)) if cpu else 0.0,
        "pred_ram": parse_float_like(ram.group(1)) if ram else 0.0,
        "pred_disk": parse_float_like(disk.group(1)) if disk else 0.0,
        "pred_gpu": 1.0 if gpu and "required" in gpu.group(1).lower() else 0.0,
        "target_node_type": target.group(1).strip() if target else None,
        "actual_node_type": actual.group(1).strip() if actual else None,
        "exit_code": int(exit_code.group(1)) if exit_code else -1,
        "kvm_cpu": float(kvm_cpu_ram.group(1)) if kvm_cpu_ram else None,
        "kvm_ram_gb": float(kvm_cpu_ram.group(2)) if kvm_cpu_ram else None,
        "kvm_flavor": flavor_name.group(1).strip() if flavor_name else None,
    }


def latest_log_key(path: Path):
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
    path = RESULT_DIR / f"{repo_name}.json"
    if not path.exists():
        return {"cpu": 0.0, "ram": 0.0, "disk": 0.0, "gpu": 0.0}
    data = json.loads(path.read_text(encoding="utf-8"))
    run_min = data.get("min_hardware", {}).get("run_min_spec", {})
    requires_gpu = bool(data.get("static_triage", {}).get("requires_gpu", False))
    return {
        "cpu": float(run_min.get("min_vcpu", 0) or 0),
        "ram": float(run_min.get("min_ram_gb", 0) or 0),
        "disk": float(run_min.get("min_disk_gb", 0) or 0),
        "gpu": 1.0 if requires_gpu else 0.0,
    }


def kvm_disk_guess(flavor):
    # Conservative flavor-root-disk guesses in GB.
    mapping = {
        "m1.tiny": 20.0,
        "m1.small": 20.0,
        "m1.medium": 40.0,
        "m1.large": 80.0,
        "m1.xlarge": 160.0,
    }
    if not flavor:
        return 40.0
    return mapping.get(flavor.strip(), 40.0)


def reserved_from_log(log_info):
    if not log_info or int(log_info.get("exit_code", -1)) != 0:
        return {"cpu": 0.0, "ram": 0.0, "disk": 0.0, "gpu": 0.0}

    node = (log_info.get("actual_node_type") or "").strip()
    if node.lower() == "kvm":
        cpu = float(log_info.get("kvm_cpu") or 0.0)
        ram = float(log_info.get("kvm_ram_gb") or 0.0)
        disk = kvm_disk_guess(log_info.get("kvm_flavor"))
        return {"cpu": cpu, "ram": ram, "disk": disk, "gpu": 0.0}

    if node in NODE_TYPE_CAPACITY:
        return dict(NODE_TYPE_CAPACITY[node])

    # Unknown successful node type: use non-zero conservative defaults.
    return {"cpu": 4.0, "ram": 8.0, "disk": 40.0, "gpu": 0.0}


def plot_resource(repos, pred, need, reserved, ylabel, title, out_path):
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


def num(v):
    return 0.0 if (isinstance(v, float) and np.isnan(v)) else float(v)


def avg_redundancy(rows, prefix):
    out = {}
    for resource in ("cpu", "ram", "disk", "gpu"):
        vals = []
        for row in rows:
            need = num(row[f"need_{resource}"])
            have = num(row[f"{prefix}_{resource}"])
            if need > 0:
                vals.append((have - need) / need * 100.0)
        out[resource] = (sum(vals) / len(vals)) if vals else None
    return out


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    hw = json.loads(HARDWARE_JSON.read_text(encoding="utf-8"))
    repo_urls = {x["url"] for x in hw}
    name_by_url = {x["url"]: x["name"] for x in hw}
    latest_logs = load_latest_logs_for_repos(repo_urls)

    rows = []
    for url in sorted(name_by_url, key=lambda u: name_by_url[u]):
        name = name_by_url[url]
        actual_need = load_actual_need(name)
        log = latest_logs.get(url, {})
        reserved = reserved_from_log(log)

        row = {
            "repo": name,
            "url": url,
            "log_path": log.get("_path"),
            "log_exit_code": int(log.get("exit_code", -1)),
            "target_node_type": log.get("target_node_type"),
            "actual_node_type": log.get("actual_node_type"),
            "pred_cpu": float(log.get("pred_cpu", 0.0) or 0.0),
            "pred_ram": float(log.get("pred_ram", 0.0) or 0.0),
            "pred_disk": float(log.get("pred_disk", 0.0) or 0.0),
            "pred_gpu": float(log.get("pred_gpu", 0.0) or 0.0),
            "need_cpu": actual_need["cpu"],
            "need_ram": actual_need["ram"],
            "need_disk": actual_need["disk"],
            "need_gpu": actual_need["gpu"],
            "reserved_cpu": reserved["cpu"],
            "reserved_ram": reserved["ram"],
            "reserved_disk": reserved["disk"],
            "reserved_gpu": reserved["gpu"],
        }
        rows.append(row)

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
        title="CPU: Predicted vs Required vs Reserved (KVM logs)",
        out_path=OUT_DIR / "cpu_comparison.png",
    )
    plot_resource(
        repos,
        pred_ram,
        need_ram,
        res_ram,
        ylabel="GB",
        title="RAM: Predicted vs Required vs Reserved (KVM logs)",
        out_path=OUT_DIR / "ram_comparison.png",
    )
    plot_resource(
        repos,
        pred_disk,
        need_disk,
        res_disk,
        ylabel="GB",
        title="Disk: Predicted vs Required vs Reserved (KVM logs)",
        out_path=OUT_DIR / "disk_comparison.png",
    )
    plot_resource(
        repos,
        pred_gpu,
        need_gpu,
        res_gpu,
        ylabel="GPU count (1=required/present)",
        title="GPU: Predicted vs Required vs Reserved (KVM logs)",
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

    total = len(rows)
    summary = {
        "repo_count": total,
        "latest_log_count_found": len(latest_logs),
        "actual_reserved_sufficient_count": reserved_sufficient,
        "actual_reserved_sufficient_ratio": (reserved_sufficient / total) if total else 0.0,
        "ai_predicted_sufficient_count": predicted_sufficient,
        "ai_predicted_sufficient_ratio": (predicted_sufficient / total) if total else 0.0,
        "average_redundancy_percent": {
            "reserved": avg_redundancy(rows, "reserved"),
            "predicted": avg_redundancy(rows, "pred"),
        },
        "reserved_capacity_assumption": "Successful reservations are converted from actual node type (or KVM flavor CPU/RAM with disk guess) into numeric capacities.",
    }

    with (OUT_DIR / "sufficiency_summary.json").open("w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2)

    with (OUT_DIR / "envagent_vs_actual_table.csv").open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)

    readme = "\n".join(
        [
            "# EnvAgent KVM Logs Comparison",
            "",
            "- Metrics compared: CPU, RAM, Disk, GPU",
            "- Series in each plot: Agent Predicted, Actual Required, Actually Reserved",
            f"- Repo count: {summary['repo_count']}",
            f"- Actual reserved sufficient ratio (all 4 resources): {summary['actual_reserved_sufficient_ratio']:.4f} ({summary['actual_reserved_sufficient_count']}/{summary['repo_count']})",
            f"- AI predicted sufficient ratio (all 4 resources): {summary['ai_predicted_sufficient_ratio']:.4f} ({summary['ai_predicted_sufficient_count']}/{summary['repo_count']})",
            f"- Average reserved redundancy (%): {summary['average_redundancy_percent']['reserved']}",
            f"- Average predicted redundancy (%): {summary['average_redundancy_percent']['predicted']}",
            "",
            "## Files",
            "- envagent_vs_actual_table.csv",
            "- sufficiency_summary.json",
            "- cpu_comparison.png",
            "- ram_comparison.png",
            "- disk_comparison.png",
            "- gpu_comparison.png",
        ]
    )
    (OUT_DIR / "README.md").write_text(readme, encoding="utf-8")


if __name__ == "__main__":
    main()
