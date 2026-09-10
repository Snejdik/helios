#!/usr/bin/env python3
"""Generate a compact Helios performance-baseline report.

Input is intentionally made only from development-time tools. Nothing here is
linked into, imported by, or executed from the shipped Helios runtime.
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import plistlib
import re
import statistics
from pathlib import Path
from typing import Any, Iterable

TARGET_NAMES = {"Helios", "HeliosDaemon"}
NAME_KEYS = (
    "name", "command", "process_name", "processName", "proc_name", "procName",
    "executable", "bundle_name", "bundleName",
)
PID_KEYS = ("pid", "process_id", "processID", "processId")


def fmt_bytes(value: float | int | None) -> str:
    if value is None:
        return "n/a"
    value = float(value)
    units = ["B", "KiB", "MiB", "GiB", "TiB"]
    idx = 0
    while abs(value) >= 1024 and idx < len(units) - 1:
        value /= 1024.0
        idx += 1
    return f"{value:.2f} {units[idx]}"


def fmt_num(value: float | None, digits: int = 2) -> str:
    return "n/a" if value is None else f"{value:.{digits}f}"


def parse_locale_number(value: str | None) -> float:
    # BSD ps follows the user's locale on macOS (for example Czech 8,2).
    # Normalize decimal commas so reports remain portable across locales.
    text = (value or "").strip().replace(",", ".")
    return float(text)


def parse_metadata(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    if not path.exists():
        return out
    for line in path.read_text(errors="replace").splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        out[key.strip()] = value.strip()
    return out


def parse_process_samples(path: Path) -> dict[str, dict[str, float | int]]:
    rows: dict[str, list[tuple[float, int]]] = {name: [] for name in TARGET_NAMES}
    if not path.exists():
        return {}
    with path.open(newline="", errors="replace") as fh:
        reader = csv.DictReader(fh, delimiter="\t")
        for row in reader:
            name = (row.get("name") or "").strip()
            if name not in TARGET_NAMES:
                continue
            try:
                cpu = parse_locale_number(row.get("cpu_percent") or "nan")
                rss_kib = int(parse_locale_number(row.get("rss_kib") or "0"))
            except ValueError:
                continue
            if math.isfinite(cpu):
                rows[name].append((cpu, rss_kib))
    result: dict[str, dict[str, float | int]] = {}
    for name, values in rows.items():
        if not values:
            continue
        cpus = [v[0] for v in values]
        rss = [v[1] * 1024 for v in values]
        result[name] = {
            "samples": len(values),
            "cpu_avg": statistics.fmean(cpus),
            "cpu_p95": sorted(cpus)[max(0, math.ceil(len(cpus) * 0.95) - 1)],
            "cpu_max": max(cpus),
            "rss_avg": statistics.fmean(rss),
            "rss_max": max(rss),
            "rss_min": min(rss),
        }
    return result


def parse_file_snapshot(path: Path) -> dict[str, int]:
    out: dict[str, int] = {}
    if not path.exists():
        return out
    with path.open(newline="", errors="replace") as fh:
        reader = csv.DictReader(fh, delimiter="\t")
        for row in reader:
            try:
                out[row["path"]] = int(row["bytes"])
            except (KeyError, ValueError):
                continue
    return out


def persistence_delta(before: Path, after: Path) -> dict[str, int]:
    a = parse_file_snapshot(before)
    b = parse_file_snapshot(after)
    return {path: b.get(path, 0) - a.get(path, 0) for path in sorted(set(a) | set(b))}


def iter_plists(path: Path) -> Iterable[Any]:
    if not path.exists() or path.stat().st_size == 0:
        return
    data = path.read_bytes()
    # powermetrics -f plist emits NUL-separated property lists. Be liberal about
    # extra whitespace so the parser survives formatting changes.
    for chunk in data.split(b"\0"):
        chunk = chunk.strip()
        if not chunk:
            continue
        try:
            yield plistlib.loads(chunk)
        except Exception:
            continue


def scalar_dict(d: dict[Any, Any]) -> dict[str, Any]:
    out: dict[str, Any] = {}
    for key, value in d.items():
        if isinstance(key, str) and isinstance(value, (str, int, float, bool)):
            out[key] = value
    return out


def interval_plists(path: Path) -> Iterable[Any]:
    # powermetrics can append a whole-run cumulative summary. Mixing it with
    # intervals double-counts the run and inflates raw counters in averages.
    # Older captures without the marker remain readable.
    for sample in iter_plists(path):
        if isinstance(sample, dict) and sample.get("is_delta") is False:
            continue
        yield sample


def identify_process(d: dict[Any, Any]) -> str | None:
    scalars = scalar_dict(d)
    for key in NAME_KEYS:
        value = scalars.get(key)
        if isinstance(value, str):
            base = Path(value).name
            for target in TARGET_NAMES:
                if base == target or value == target:
                    return target
    # Fallback: some powermetrics versions encode the command in a less stable
    # key. Search scalar string values, but require exact basename match.
    for value in scalars.values():
        if isinstance(value, str) and Path(value).name in TARGET_NAMES:
            return Path(value).name
    return None


def walk_dicts(obj: Any) -> Iterable[dict[Any, Any]]:
    if isinstance(obj, dict):
        yield obj
        for value in obj.values():
            yield from walk_dicts(value)
    elif isinstance(obj, list):
        for item in obj:
            yield from walk_dicts(item)


def powermetrics_process_records(path: Path) -> dict[str, list[dict[str, Any]]]:
    records: dict[str, list[dict[str, Any]]] = {name: [] for name in TARGET_NAMES}
    for plist in interval_plists(path):
        for d in walk_dicts(plist):
            name = identify_process(d)
            if not name:
                continue
            scalars = scalar_dict(d)
            if scalars:
                records[name].append(scalars)
    return {k: v for k, v in records.items() if v}


def numeric_summary(records: list[dict[str, Any]]) -> dict[str, dict[str, float]]:
    values: dict[str, list[float]] = {}
    for record in records:
        for key, value in record.items():
            if isinstance(value, bool):
                continue
            if isinstance(value, (int, float)) and math.isfinite(float(value)):
                # PIDs and identifiers are not performance metrics.
                lower = key.lower()
                if lower in PID_KEYS or lower.endswith("pid") or "timestamp" in lower:
                    continue
                values.setdefault(key, []).append(float(value))
    summary: dict[str, dict[str, float]] = {}
    for key, nums in values.items():
        if not nums:
            continue
        summary[key] = {
            "samples": float(len(nums)),
            "avg": statistics.fmean(nums),
            "max": max(nums),
            "last": nums[-1],
        }
    return summary


def likely_metric_keys(summary: dict[str, dict[str, float]]) -> list[str]:
    hints = (
        "wake", "cpu", "energy", "disk", "io", "read", "write", "byte",
        "network", "gpu", "timer", "interrupt", "idle", "power",
    )
    return [k for k in sorted(summary) if any(h in k.lower() for h in hints)]


def thermal_scalar_samples(path: Path) -> dict[str, dict[str, float]]:
    values: dict[str, list[float]] = {}
    hints = ("temp", "thermal", "fan", "power", "watt", "pressure")
    for plist in interval_plists(path):
        for d in walk_dicts(plist):
            for key, value in scalar_dict(d).items():
                if isinstance(value, bool) or not isinstance(value, (int, float)):
                    continue
                if any(h in key.lower() for h in hints):
                    values.setdefault(key, []).append(float(value))
    out: dict[str, dict[str, float]] = {}
    for key, nums in values.items():
        if nums:
            out[key] = {"avg": statistics.fmean(nums), "min": min(nums), "max": max(nums)}
    return out


def render_report(run_dir: Path) -> str:
    meta = parse_metadata(run_dir / "metadata.txt")
    proc = parse_process_samples(run_dir / "process-samples.tsv")
    deltas = persistence_delta(run_dir / "persistence-before.tsv", run_dir / "persistence-after.tsv")
    pm_records = powermetrics_process_records(run_dir / "powermetrics.plist")
    thermal = thermal_scalar_samples(run_dir / "powermetrics.plist")

    lines: list[str] = []
    scenario = meta.get("scenario", run_dir.name)
    lines += [f"# Helios performance baseline — {scenario}", ""]
    lines += [
        f"- Duration: {meta.get('duration_seconds', 'unknown')} s",
        f"- Started: {meta.get('started_at', 'unknown')}",
        f"- macOS: {meta.get('macos', 'unknown')}",
        f"- Hardware: {meta.get('hardware_model', 'unknown')}",
        f"- Power source: {meta.get('power_source', 'unknown')}",
        f"- powermetrics samplers: {meta.get('powermetrics_samplers', 'unknown')}",
        f"- Source fingerprint: `{meta.get('source_fingerprint', 'unknown')}`",
        f"- App build configuration: {meta.get('app_build_configuration', 'unknown')}",
        f"- App executable: `{meta.get('app_command', 'not recorded')}`",
        "",
    ]

    lines += ["## Process sampling", ""]
    if proc:
        lines += ["| Process | Samples | Avg CPU % | P95 CPU % | Max CPU % | Avg RSS | Max RSS |", "|---|---:|---:|---:|---:|---:|---:|"]
        for name in ("Helios", "HeliosDaemon"):
            row = proc.get(name)
            if not row:
                continue
            lines.append(
                f"| {name} | {row['samples']} | {row['cpu_avg']:.3f} | {row['cpu_p95']:.3f} | "
                f"{row['cpu_max']:.3f} | {fmt_bytes(row['rss_avg'])} | {fmt_bytes(row['rss_max'])} |"
            )
    else:
        lines.append("No Helios process samples were captured.")
    lines.append("")

    lines += ["## Local persistence growth", ""]
    relevant = [(p, d) for p, d in deltas.items() if d != 0 or Path(p).name in {
        "history-v1.ndjson", "io-activity-v1.ndjson", "app-energy-v1.ndjson", "health-events-v1.ndjson"
    }]
    if relevant:
        lines += ["| File | Delta |", "|---|---:|"]
        for path, delta in relevant:
            lines.append(f"| `{Path(path).name}` | {fmt_bytes(delta)} ({delta:+d} B) |")
    else:
        lines.append("No measured Application Support/Helios file growth.")
    lines.append("")

    lines += ["## powermetrics — Helios process records", ""]
    if not pm_records:
        lines.append("No matching Helios records were decoded from powermetrics plist output. Inspect `powermetrics.plist` and `powermetrics-help.txt`.")
    for name in ("Helios", "HeliosDaemon"):
        records = pm_records.get(name)
        if not records:
            continue
        summary = numeric_summary(records)
        keys = likely_metric_keys(summary)
        lines.append(f"### {name}")
        lines.append("")
        lines.append(f"Decoded process dictionaries: {len(records)}")
        lines.append("")
        if keys:
            lines += ["| Metric key | Avg | Max | Last |", "|---|---:|---:|---:|"]
            for key in keys[:40]:
                s = summary[key]
                lines.append(f"| `{key}` | {s['avg']:.4g} | {s['max']:.4g} | {s['last']:.4g} |")
        else:
            lines.append("Process dictionaries were found, but no likely performance scalar keys were identified automatically.")
        lines.append("")

    lines += ["## System thermal / power scalar candidates", ""]
    if thermal:
        lines += ["| Metric key | Avg | Min | Max |", "|---|---:|---:|---:|"]
        for key in sorted(thermal)[:50]:
            s = thermal[key]
            lines.append(f"| `{key}` | {s['avg']:.4g} | {s['min']:.4g} | {s['max']:.4g} |")
    else:
        lines.append("No thermal/power scalar candidates were available from the samplers on this run.")
    lines.append("")

    lines += [
        "## Interpretation guardrails",
        "",
        "- Compare the same scenario before/after on the same Mac and power state.",
        "- Lower CPU time, wakeups, energy proxy and write volume are better; higher idle residency is better when present.",
        "- powermetrics energy is a relative optimization signal, not a billing-grade physical energy meter.",
        "- Explicit cumulative powermetrics summaries are excluded from interval statistics.",
        "- Thermal values are system-level and can be influenced by unrelated workloads, ambient temperature and charging.",
        "- A performance change is not accepted until Helios regression gates and the real-Mac Xcode build still pass.",
        "",
    ]
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("run_dir", type=Path)
    parser.add_argument("--json", action="store_true", help="also emit decoded powermetrics process records as JSON")
    args = parser.parse_args()
    run_dir = args.run_dir.resolve()
    report = render_report(run_dir)
    (run_dir / "REPORT.md").write_text(report)
    if args.json:
        records = powermetrics_process_records(run_dir / "powermetrics.plist")
        (run_dir / "powermetrics-helios-records.json").write_text(json.dumps(records, indent=2, sort_keys=True))
    print(report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
