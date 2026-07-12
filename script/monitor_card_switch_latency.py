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


def gate_status(
    measurement: tuple[int, float, float, float],
    *,
    completed_count: int,
    max_total_ms: float | None,
    sample_count: int | None,
) -> str:
    if max_total_ms is not None and measurement[3] > max_total_ms:
        return "fail"
    if sample_count is not None and completed_count >= sample_count:
        return "pass"
    return "continue"


def sample_gate_incomplete(*, completed_count: int, sample_count: int | None) -> bool:
    return sample_count is not None and completed_count < sample_count


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


def stream_measurements(max_total_ms: float | None, sample_count: int | None) -> None:
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
    gate_failed = False
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
            status = gate_status(
                measurement,
                completed_count=len(measurements),
                max_total_ms=max_total_ms,
                sample_count=sample_count,
            )
            if status == "fail":
                gate_failed = True
                print(
                    f"Card switch probe {probe} exceeded {max_total_ms:.3f} ms: {total:.3f} ms",
                    file=sys.stderr,
                    flush=True,
                )
                raise SystemExit(1)
            if status == "pass":
                break
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
        if not gate_failed and sample_gate_incomplete(
            completed_count=len(measurements),
            sample_count=sample_count,
        ):
            print(
                f"Incomplete card switch gate: received {len(measurements)} of {sample_count} samples",
                file=sys.stderr,
            )
            raise SystemExit(2)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="validate parsing and percentile calculations without streaming logs",
    )
    parser.add_argument(
        "--max-total-ms",
        type=float,
        help="exit 1 immediately when one completed switch exceeds this total latency",
    )
    parser.add_argument(
        "--sample-count",
        type=int,
        help="exit 0 after this many completed switches remain within the threshold",
    )
    arguments = parser.parse_args()
    if arguments.max_total_ms is not None and arguments.max_total_ms <= 0:
        parser.error("--max-total-ms must be greater than zero")
    if arguments.sample_count is not None and arguments.sample_count <= 0:
        parser.error("--sample-count must be greater than zero")
    if arguments.self_test:
        sample = (
            "cardSwitchCompleted probe=7 "
            "recognitionMs=3.250 applyMs=1.500 totalMs=4.750"
        )
        assert parse_measurement(sample) == (7, 3.25, 1.5, 4.75)
        assert percentile([1.0, 2.0, 9.0, 10.0], 0.95) == 10.0
        assert gate_status((7, 3.25, 1.5, 4.75), completed_count=10, max_total_ms=100, sample_count=10) == "pass"
        assert sample_gate_incomplete(completed_count=9, sample_count=10)
        print("card switch monitor self-test passed")
        return
    stream_measurements(arguments.max_total_ms, arguments.sample_count)


if __name__ == "__main__":
    main()
