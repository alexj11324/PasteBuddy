#!/usr/bin/env python3
"""Stream privacy-safe PasteBuddy card-switch latency diagnostics."""

from __future__ import annotations

import argparse
import math
import re
import subprocess
import sys
from collections.abc import Sequence


MEASUREMENT_PATTERN = re.compile(
    r"cardSwitchCompleted\s+probe=(\d+)\s+"
    r"recognitionMs=([0-9.]+)\s+applyMs=([0-9.]+)\s+totalMs=([0-9.]+)"
)


def parse_measurement(line: str) -> tuple[int, float, float, float] | None:
    match = MEASUREMENT_PATTERN.search(line)
    if match is None:
        return None
    return (
        int(match.group(1)),
        float(match.group(2)),
        float(match.group(3)),
        float(match.group(4)),
    )


def percentile(values: Sequence[float], quantile: float) -> float:
    if not values:
        raise ValueError("percentile requires at least one value")
    ordered = sorted(values)
    rank = max(1, math.ceil(quantile * len(ordered)))
    return ordered[rank - 1]


def print_summary(measurements: Sequence[tuple[int, float, float, float]]) -> None:
    if not measurements:
        print("\nNo completed card switches recorded.")
        return
    totals = [measurement[3] for measurement in measurements]
    recognition = [measurement[1] for measurement in measurements]
    apply = [measurement[2] for measurement in measurements]
    print("\nCard switch latency summary (ms)")
    print("phase         count      p50      p95      max")
    for name, values in (
        ("recognition", recognition),
        ("apply", apply),
        ("total", totals),
    ):
        print(
            f"{name:<13}{len(values):>5}"
            f"{percentile(values, 0.50):>9.3f}"
            f"{percentile(values, 0.95):>9.3f}"
            f"{max(values):>9.3f}"
        )


def stream_measurements() -> None:
    predicate = (
        'process == "PasteBuddy" AND '
        'subsystem == "com.alexjiang.PasteBuddy.dev" AND '
        'category == "Diagnostics"'
    )
    command = [
        "/usr/bin/log",
        "stream",
        "--info",
        "--style",
        "compact",
        "--predicate",
        predicate,
    ]
    measurements: list[tuple[int, float, float, float]] = []
    print("Monitoring PasteBuddy card switches. Press Ctrl-C for summary.")
    print("probe  recognitionMs  applyMs  totalMs")
    process = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    try:
        assert process.stdout is not None
        for line in process.stdout:
            measurement = parse_measurement(line)
            if measurement is None:
                continue
            measurements.append(measurement)
            probe, recognition, apply, total = measurement
            print(f"{probe:>5}  {recognition:>13.3f}  {apply:>7.3f}  {total:>7.3f}")
    except KeyboardInterrupt:
        pass
    finally:
        if process.poll() is None:
            process.terminate()
        process.wait(timeout=5)
        if process.returncode not in (0, -15):
            assert process.stderr is not None
            error = process.stderr.read().strip()
            if error:
                print(error, file=sys.stderr)
            raise SystemExit(process.returncode)
        print_summary(measurements)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="validate parsing and percentile calculations without streaming logs",
    )
    arguments = parser.parse_args()
    if arguments.self_test:
        sample = (
            "cardSwitchCompleted probe=7 "
            "recognitionMs=3.250 applyMs=1.500 totalMs=4.750"
        )
        assert parse_measurement(sample) == (7, 3.25, 1.5, 4.75)
        assert percentile([1.0, 2.0, 9.0, 10.0], 0.95) == 10.0
        print("card switch monitor self-test passed")
        return
    stream_measurements()


if __name__ == "__main__":
    main()
