#!/usr/bin/env python3
"""Compare two Helios perf-baseline run directories."""
from __future__ import annotations

import argparse
import csv
import json
import math
import statistics
from pathlib import Path

TARGETS = ("Helios", "HeliosDaemon")
HINTS = ("wake", "cpu", "energy", "disk", "io", "read", "write", "byte", "network", "gpu", "timer", "interrupt", "idle", "power")


def parse_locale_number(value: str | None) -> float:
    return float((value or "").strip().replace(",", "."))


def process_stats(path: Path):
    rows = {name: [] for name in TARGETS}
    p = path / "process-samples.tsv"
    if not p.exists():
        return {}
    with p.open(newline="", errors="replace") as f:
        for row in csv.DictReader(f, delimiter="\t"):
            name = row.get("name", "")
            if name not in rows:
                continue
            try:
                cpu = parse_locale_number(row["cpu_percent"])
                rss = int(parse_locale_number(row["rss_kib"])) * 1024
            except (KeyError, ValueError):
                continue
            if math.isfinite(cpu):
                rows[name].append((cpu, rss))
    out = {}
    for name, values in rows.items():
        if not values:
            continue
        cpus = [x[0] for x in values]
        rss = [x[1] for x in values]
        out[name] = {
            "cpu_avg": statistics.fmean(cpus),
            "cpu_p95": sorted(cpus)[max(0, math.ceil(len(cpus) * .95) - 1)],
            "rss_avg": statistics.fmean(rss),
            "rss_max": max(rss),
        }
    return out


def file_sizes(path: Path, filename: str):
    p = path / filename
    out = {}
    if not p.exists():
        return out
    with p.open(newline="", errors="replace") as f:
        for row in csv.DictReader(f, delimiter="\t"):
            try:
                out[row["path"]] = int(row["bytes"])
            except (KeyError, ValueError):
                pass
    return out


def persistence_growth(path: Path):
    before = file_sizes(path, "persistence-before.tsv")
    after = file_sizes(path, "persistence-after.tsv")
    return sum(after.get(k, 0) - before.get(k, 0) for k in set(before) | set(after))


def pm_stats(path: Path):
    p = path / "powermetrics-helios-records.json"
    if not p.exists():
        return {}
    try:
        records = json.loads(p.read_text())
    except Exception:
        return {}
    out = {}
    for name in TARGETS:
        metrics = {}
        for record in records.get(name, []):
            for key, value in record.items():
                if isinstance(value, bool) or not isinstance(value, (int, float)):
                    continue
                if not any(h in key.lower() for h in HINTS):
                    continue
                metrics.setdefault(key, []).append(float(value))
        out[name] = {k: statistics.fmean(v) for k, v in metrics.items() if v}
    return out


def pct(before: float, after: float):
    if before == 0:
        return None
    return (after - before) / abs(before) * 100.0


def fmt_delta(before: float, after: float, suffix: str = ""):
    d = after - before
    p = pct(before, after)
    ps = "n/a" if p is None else f"{p:+.1f}%"
    return f"{before:.3f}{suffix} → {after:.3f}{suffix} ({d:+.3f}{suffix}, {ps})"


def fmt_bytes(n: float):
    sign = "-" if n < 0 else ""
    n = abs(float(n))
    for unit in ("B", "KiB", "MiB", "GiB"):
        if n < 1024 or unit == "GiB":
            return f"{sign}{n:.2f} {unit}"
        n /= 1024
    return f"{sign}{n:.2f} GiB"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("before", type=Path)
    ap.add_argument("after", type=Path)
    args = ap.parse_args()
    b, a = args.before.resolve(), args.after.resolve()
    bs, as_ = process_stats(b), process_stats(a)
    bpm, apm = pm_stats(b), pm_stats(a)

    lines = [f"# Helios performance comparison", "", f"Before: `{b}`", f"After: `{a}`", ""]
    lines += ["## CPU / memory", "", "| Process | Metric | Before → after |", "|---|---|---|"]
    any_row = False
    for name in TARGETS:
        if name not in bs or name not in as_:
            continue
        any_row = True
        lines.append(f"| {name} | Avg CPU | {fmt_delta(bs[name]['cpu_avg'], as_[name]['cpu_avg'], '%')} |")
        lines.append(f"| {name} | P95 CPU | {fmt_delta(bs[name]['cpu_p95'], as_[name]['cpu_p95'], '%')} |")
        lines.append(f"| {name} | Avg RSS | {fmt_bytes(bs[name]['rss_avg'])} → {fmt_bytes(as_[name]['rss_avg'])} ({fmt_bytes(as_[name]['rss_avg']-bs[name]['rss_avg'])}) |")
        lines.append(f"| {name} | Max RSS | {fmt_bytes(bs[name]['rss_max'])} → {fmt_bytes(as_[name]['rss_max'])} ({fmt_bytes(as_[name]['rss_max']-bs[name]['rss_max'])}) |")
    if not any_row:
        lines.append("| — | — | No comparable process samples |")
    lines.append("")

    bg, ag = persistence_growth(b), persistence_growth(a)
    lines += ["## Local persistence writes", "", f"Measured file growth: {fmt_bytes(bg)} → {fmt_bytes(ag)} ({fmt_bytes(ag-bg)})", ""]

    lines += ["## Common powermetrics scalar keys", ""]
    for name in TARGETS:
        common = sorted(set(bpm.get(name, {})) & set(apm.get(name, {})))
        if not common:
            continue
        lines += [f"### {name}", "", "| Metric key | Before → after |", "|---|---:|"]
        for key in common[:50]:
            lines.append(f"| `{key}` | {fmt_delta(bpm[name][key], apm[name][key])} |")
        lines.append("")
    lines += [
        "Negative deltas are improvements for CPU, RSS, wakeup/energy/write-like metrics. Interpret idle-residency metrics in the opposite direction (higher is better).",
        "",
    ]
    text = "\n".join(lines)
    out = a / f"COMPARE-vs-{b.name}.md"
    out.write_text(text)
    print(text)
    print(f"\nWrote {out}")


if __name__ == "__main__":
    main()
