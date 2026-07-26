#!/usr/bin/env python3
"""Run the existing Dify localization workflow and materialize String Catalogs."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DIFY_SCRIPT = ROOT / "script/localize_with_dify.py"
CATALOG_SCRIPT = ROOT / "script/localization_catalog_workflow.py"
STRING_CATALOG = ROOT / "Sources/PasteBuddy/Resources/Localizable.xcstrings"
STRING_PAIR_RE = re.compile(r'"((?:\\.|[^"\\])*)"\s*=\s*"((?:\\.|[^"\\])*)"\s*;')


def run(command: list[str]) -> None:
    print("+ " + " ".join(command))
    subprocess.run(command, cwd=ROOT, check=True)


def catalog_values(locale: str) -> dict[str, str]:
    payload = json.loads(STRING_CATALOG.read_text(encoding="utf-8"))
    values: dict[str, str] = {}
    for key, entry in payload["strings"].items():
        value = entry.get("localizations", {}).get(locale, {}).get("stringUnit", {}).get("value")
        if isinstance(value, str):
            values[key] = value
    return values


def write_interchange(path: Path, values: dict[str, str]) -> None:
    lines = [
        f"{json.dumps(key, ensure_ascii=False)} = {json.dumps(value, ensure_ascii=False)};"
        for key, value in sorted(values.items())
    ]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def read_interchange(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        match = STRING_PAIR_RE.search(line)
        if match:
            values[json.loads(f'"{match.group(1)}"')] = json.loads(f'"{match.group(2)}"')
    return values


def merge_interchange(source: Path, target: Path, target_locale: str) -> None:
    payload = json.loads(STRING_CATALOG.read_text(encoding="utf-8"))
    english = read_interchange(source)
    translated = read_interchange(target)
    for key, entry in payload["strings"].items():
        if key in english:
            entry.setdefault("localizations", {}).setdefault("en", {})["stringUnit"] = {
                "state": "translated",
                "value": english[key],
            }
        if key in translated:
            entry.setdefault("localizations", {}).setdefault(target_locale, {})["stringUnit"] = {
                "state": "translated",
                "value": translated[key],
            }
    STRING_CATALOG.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


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
        with tempfile.TemporaryDirectory(prefix="pastebuddy-localization-") as directory:
            source = Path(directory) / "en.strings"
            target = Path(directory) / f"{args.target_locale}.strings"
            write_interchange(source, catalog_values("en"))
            write_interchange(target, catalog_values(args.target_locale))
            dify_command = [
                sys.executable,
                str(DIFY_SCRIPT),
                "--source",
                str(source),
                "--target",
                str(target),
                "--mode",
                args.mode,
                "--target-locale",
                args.target_locale,
                "--workflow-mode",
                args.workflow_mode,
                "--no-code-scan",
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
            run(dify_command)
            if args.mode != "apply":
                return 0
            merge_interchange(source, target, args.target_locale)

    sync_command = [sys.executable, str(CATALOG_SCRIPT), "sync"]
    if not args.no_rewrite_swift:
        sync_command.append("--rewrite-swift")
    run(sync_command)
    run([sys.executable, str(CATALOG_SCRIPT), "check"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
