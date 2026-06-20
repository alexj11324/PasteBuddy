#!/usr/bin/env python3
"""Run the existing Dify localization workflow and materialize String Catalogs."""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DIFY_SCRIPT = ROOT / "script/localize_with_dify.py"
CATALOG_SCRIPT = ROOT / "script/localization_catalog_workflow.py"


def run(command: list[str]) -> None:
    print("+ " + " ".join(command))
    subprocess.run(command, cwd=ROOT, check=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=["scan", "translate", "apply"], default="apply")
    parser.add_argument("--target-locale", default="zh-Hans")
    parser.add_argument("--workflow-mode", choices=["incremental", "full_app", "review_only"], default="incremental")
    parser.add_argument("--dify-url", default=None)
    parser.add_argument("--api-key-env", default=None)
    parser.add_argument("--secret-name", default=None)
    parser.add_argument("--secret-project", default=None)
    parser.add_argument("--chunk-size", type=int, default=None)
    parser.add_argument("--include-existing", action="store_true")
    parser.add_argument("--no-code-scan", action="store_true")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--input-result", type=Path)
    parser.add_argument("--skip-dify", action="store_true", help="Only materialize and check local catalog files.")
    parser.add_argument("--no-rewrite-swift", action="store_true")
    args = parser.parse_args()

    if not args.skip_dify:
        dify_command = [
            sys.executable,
            str(DIFY_SCRIPT),
            "--mode",
            args.mode,
            "--target-locale",
            args.target_locale,
            "--workflow-mode",
            args.workflow_mode,
        ]
        optional_args = {
            "--dify-url": args.dify_url,
            "--api-key-env": args.api_key_env,
            "--secret-name": args.secret_name,
            "--secret-project": args.secret_project,
            "--chunk-size": str(args.chunk_size) if args.chunk_size else None,
            "--output": str(args.output) if args.output else None,
            "--input-result": str(args.input_result) if args.input_result else None,
        }
        for flag, value in optional_args.items():
            if value:
                dify_command.extend([flag, value])
        if args.include_existing:
            dify_command.append("--include-existing")
        if args.no_code_scan:
            dify_command.append("--no-code-scan")
        run(dify_command)
        if args.mode != "apply":
            return 0

    sync_command = [sys.executable, str(CATALOG_SCRIPT), "sync"]
    if not args.no_rewrite_swift:
        sync_command.append("--rewrite-swift")
    run(sync_command)
    run([sys.executable, str(CATALOG_SCRIPT), "check"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
