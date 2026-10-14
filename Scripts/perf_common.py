"""What the app and Ghostty perf scripts share: the workload's scales and
command, process samples, their summaries and the baseline comparisons.

Scripts/perf-app-soak (Cherry) and Scripts/perf-ghostty-workload (the Ghostty
control) run Scripts/perf-terminal-workload with the same values per scale, so
Scripts/perf-compare-emulators can compare their reports.
"""

from pathlib import Path
import shlex
import subprocess


WORKLOAD_SCRIPT = Path(__file__).resolve().parent / "perf-terminal-workload"

# The workload and sampling of each scale, in both emulators.
WORKLOAD_SCALES = {
    "smoke": {
        "duration": 20,
        "lines": 8_000,
        "frames": 150,
        "progress_frames": 300,
        "sleep_ms": 0,
        "rate_mib_per_second": 4.0,
        "sample_interval": 2.0,
    },
    "standard": {
        "duration": 180,
        "lines": 50_000,
        "frames": 1_000,
        "progress_frames": 2_000,
        "sleep_ms": 0,
        "rate_mib_per_second": 2.0,
        "sample_interval": 5.0,
    },
    "soak": {
        "duration": 7_200,
        "lines": 120_000,
        "frames": 6_000,
        "progress_frames": 10_000,
        "sleep_ms": 0,
        "rate_mib_per_second": 1.0,
        "sample_interval": 30.0,
    },
}


def setting(args, scales, key):
    """The option `key` when it was given, else its value at the run's scale."""
    value = getattr(args, key)
    return value if value is not None else scales[args.scale][key]


def shell_command(mode, duration, lines, frames, progress_frames, sleep_ms, rate_mib_per_second):
    command = [
        str(WORKLOAD_SCRIPT),
        mode,
        "--duration",
        str(max(1, int(duration))),
        "--lines",
        str(lines),
        "--frames",
        str(frames),
        "--progress-frames",
        str(progress_frames),
        "--sleep-ms",
        str(max(0, sleep_ms)),
        "--rate-mib-per-second",
        str(max(0, rate_mib_per_second)),
    ]
    return " ".join(shlex.quote(part) for part in command)


def sample_processes(pids):
    """RSS and CPU of those of `pids` that still run. ps(1) lists the ones it
    finds even when others are gone (it then exits 1)."""
    if not pids:
        return {"processes": [], "total_rss_bytes": 0, "total_cpu_percent": 0.0}

    try:
        output = subprocess.run(
            [
                "/bin/ps",
                "-o",
                "pid=,rss=,pcpu=,etime=",
                "-p",
                ",".join(str(pid) for pid in pids),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=2,
        ).stdout
    except Exception as error:
        return {
            "processes": [],
            "total_rss_bytes": 0,
            "total_cpu_percent": 0.0,
            "error": str(error),
        }

    processes = []
    for line in output.splitlines():
        parts = line.split()
        if len(parts) < 4:
            continue
        try:
            pid = int(parts[0])
            rss_bytes = int(parts[1]) * 1024
            cpu_percent = float(parts[2])
        except ValueError:
            continue
        processes.append({
            "pid": pid,
            "rss_bytes": rss_bytes,
            "cpu_percent": cpu_percent,
            "elapsed": parts[3],
        })

    return {
        "processes": processes,
        "total_rss_bytes": sum(process["rss_bytes"] for process in processes),
        "total_cpu_percent": sum(process["cpu_percent"] for process in processes),
    }


def summarize_samples(samples):
    """RSS and CPU over a run's samples (`sample_processes` results with
    `elapsed_seconds`)."""
    if not samples:
        return {
            "sample_count": 0,
            "first_total_rss_bytes": 0,
            "last_total_rss_bytes": 0,
            "min_total_rss_bytes": 0,
            "max_total_rss_bytes": 0,
            "rss_delta_bytes": 0,
            "rss_growth_bytes_per_second": 0.0,
            "rss_growth_mib_per_hour": 0.0,
            "max_total_cpu_percent": 0.0,
            "max_process_rss_bytes": 0,
        }

    ordered = sorted(samples, key=lambda sample: sample.get("elapsed_seconds", 0.0))
    first = ordered[0]
    last = ordered[-1]
    elapsed = max(0.0, float(last.get("elapsed_seconds", 0.0)) - float(first.get("elapsed_seconds", 0.0)))
    first_rss = int(first.get("total_rss_bytes", 0))
    last_rss = int(last.get("total_rss_bytes", 0))
    rss_delta = last_rss - first_rss
    rss_growth = (rss_delta / elapsed) if elapsed > 0 else 0.0

    max_process_rss = 0
    for sample in ordered:
        for process in sample.get("processes", []):
            max_process_rss = max(max_process_rss, process.get("rss_bytes", 0))

    return {
        "sample_count": len(ordered),
        "first_total_rss_bytes": first_rss,
        "last_total_rss_bytes": last_rss,
        "min_total_rss_bytes": min(sample.get("total_rss_bytes", 0) for sample in ordered),
        "max_total_rss_bytes": max(sample.get("total_rss_bytes", 0) for sample in ordered),
        "rss_delta_bytes": rss_delta,
        "rss_growth_bytes_per_second": rss_growth,
        "rss_growth_mib_per_hour": (rss_growth * 3600) / 1_048_576,
        "max_total_cpu_percent": max(sample.get("total_cpu_percent", 0.0) for sample in ordered),
        "max_process_rss_bytes": max_process_rss,
    }


def performance_totals(sample):
    """Cherry's diagnostic counters across a sample's project windows."""
    statuses = [
        entry["status"]
        for entry in sample.get("performance", [])
        if isinstance(entry, dict) and isinstance(entry.get("status"), dict)
    ]
    if not statuses:
        return None

    def value(status, key, default=0):
        return status.get(key, default) or default

    def counter(status, key, default=0):
        return (status.get("terminalPerfCounters") or {}).get(key, default) or default

    return {
        "process_count": sum((status.get("processCounts") or {}).get("total", 0) for status in statuses),
        "ghostty_live_bridge_count": max(value(status, "ghosttyLiveBridgeCount") for status in statuses),
        "ghostty_output_observer_count": max(value(status, "ghosttyInstalledOutputObserverCount") for status in statuses),
        "raw_output_observer_count": sum(value(status, "rawOutputObserverCount") for status in statuses),
        "terminal_perf_enabled": any(bool(status.get("terminalPerfEnabled")) for status in statuses),
        "ghostty_feed_chunks": max(counter(status, "ghosttyFeedChunks") for status in statuses),
        "ghostty_feed_bytes": max(counter(status, "ghosttyFeedBytes") for status in statuses),
        "bridge_attaches": max(counter(status, "bridgeAttaches") for status in statuses),
        "render_ticks": max(counter(status, "renderTicks") for status in statuses),
    }


def rss_drift(prefix, start, end):
    elapsed = max(0.0, float(end.get("elapsed_seconds", 0.0)) - float(start.get("elapsed_seconds", 0.0)))
    start_rss = int(start.get("total_rss_bytes", 0))
    end_rss = int(end.get("total_rss_bytes", 0))
    delta = end_rss - start_rss
    growth = (delta / elapsed) if elapsed > 0 else 0.0
    return {
        f"{prefix}_start_label": start.get("label", ""),
        f"{prefix}_end_label": end.get("label", ""),
        f"{prefix}_elapsed_seconds": elapsed,
        f"{prefix}_start_total_rss_bytes": start_rss,
        f"{prefix}_end_total_rss_bytes": end_rss,
        f"{prefix}_rss_delta_bytes": delta,
        f"{prefix}_rss_growth_mib_per_hour": (growth * 3600) / 1_048_576,
    }


def steady_state_drift(ordered_samples):
    empty = {
        "steady_state_start_label": "",
        "steady_state_end_label": "",
        "steady_state_elapsed_seconds": 0.0,
        "steady_state_start_total_rss_bytes": 0,
        "steady_state_end_total_rss_bytes": 0,
        "steady_state_rss_delta_bytes": 0,
        "steady_state_rss_growth_mib_per_hour": 0.0,
    }
    start = next((sample for sample in ordered_samples if sample.get("label") == "after_spawn"), None)
    if start is None:
        return empty

    start_elapsed = float(start.get("elapsed_seconds", 0.0))
    end_labels = {"during_selection", "before_close", "failure"}
    candidates = [
        sample for sample in ordered_samples
        if sample is not start
        and float(sample.get("elapsed_seconds", 0.0)) >= start_elapsed
        and sample.get("label") in end_labels
    ]
    end = candidates[-1] if candidates else start
    return rss_drift("steady_state", start, end)


def summarize_app_samples(samples):
    """`summarize_samples` of an app soak, with the drift after its workloads
    started and Cherry's diagnostic counters."""
    ordered = sorted(samples, key=lambda sample: sample.get("elapsed_seconds", 0.0))
    performance_samples = [
        totals for sample in ordered
        if (totals := performance_totals(sample)) is not None
    ]
    last_performance = performance_samples[-1] if performance_samples else {}

    return {
        **summarize_samples(ordered),
        **steady_state_drift(ordered),
        "performance_sample_count": len(performance_samples),
        "max_ghostty_live_bridge_count": max((sample["ghostty_live_bridge_count"] for sample in performance_samples), default=0),
        "last_ghostty_live_bridge_count": last_performance.get("ghostty_live_bridge_count", 0),
        "max_ghostty_output_observer_count": max((sample["ghostty_output_observer_count"] for sample in performance_samples), default=0),
        "last_ghostty_output_observer_count": last_performance.get("ghostty_output_observer_count", 0),
        "max_raw_output_observer_count": max((sample["raw_output_observer_count"] for sample in performance_samples), default=0),
        "last_raw_output_observer_count": last_performance.get("raw_output_observer_count", 0),
        "last_terminal_perf_ghostty_feed_chunks": last_performance.get("ghostty_feed_chunks", 0),
        "last_terminal_perf_ghostty_feed_bytes": last_performance.get("ghostty_feed_bytes", 0),
        "last_terminal_perf_bridge_attaches": last_performance.get("bridge_attaches", 0),
        "last_terminal_perf_render_ticks": last_performance.get("render_ticks", 0),
    }


def compare_upper(failures, metric, current, baseline, tolerance):
    if current is None or baseline is None or baseline <= 0:
        return
    limit = baseline * (1 + tolerance)
    if current > limit:
        failures.append(
            f"{metric} regressed: {current:.3f} > {limit:.3f} "
            f"(baseline {baseline:.3f}, tolerance {tolerance * 100:.1f}%)"
        )


def compare_lower(failures, metric, current, baseline, tolerance):
    if current is None or baseline is None or baseline <= 0:
        return
    limit = baseline * (1 - tolerance)
    if current < limit:
        failures.append(
            f"{metric} regressed: {current:.3f} < {limit:.3f} "
            f"(baseline {baseline:.3f}, tolerance {tolerance * 100:.1f}%)"
        )


def compare_with_slack(failures, metric, current, baseline, tolerance, slack):
    if current is None or baseline is None:
        return
    limit = max(baseline, 0) * (1 + tolerance) + slack
    if current > limit:
        failures.append(
            f"{metric} regressed: {current:.3f} > {limit:.3f} "
            f"(baseline {baseline:.3f}, tolerance {tolerance * 100:.1f}%, slack {slack:.3f})"
        )
