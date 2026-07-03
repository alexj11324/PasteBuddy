#!/usr/bin/env python3
"""Extract and localize PasteBuddy strings through the Dify workflow app."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SOURCE = ROOT / "Sources/PasteBuddy/Resources/en.lproj/Localizable.strings"
DEFAULT_TARGET = ROOT / "Sources/PasteBuddy/Resources/zh-Hans.lproj/Localizable.strings"
DEFAULT_DIFY_URL = "https://dify.nebula-spaces.com/v1/workflows/run"
DEFAULT_SECRET_NAME = "dify-pastebuddy-localization-workflow-api-key"
DEFAULT_SECRET_PROJECT = "general-secrets-store"

STRING_PAIR_RE = re.compile(r'"((?:\\.|[^"\\])*)"\s*=\s*"((?:\\.|[^"\\])*)"\s*;')
STRING_LITERAL_RE = re.compile(r'"((?:\\.|[^"\\])*)"')
LOCALIZED_CALL_RE = re.compile(
    r"(?:NSLocalizedString|localized(?:Format)?|PasteBuddyLocalization\.(?:string|format))"
    r"\(\s*\"((?:\\.|[^\"\\])*)\""
)
DEFAULT_VALUE_CALL_RE = re.compile(
    r"(?:PasteBuddyLocalization\.(?:string|format)|localized(?:Format)?)"
    r"\(\s*\"((?:\\.|[^\"\\])*)\"\s*,\s*defaultValue:\s*\"((?:\\.|[^\"\\])*)\""
)
PLACEHOLDER_RE = re.compile(r"%(?:\d+\$)?(?:lld|llu|ld|lu|@|[diuoxXfFeEgGcCsSpaA])")
HTML_TAG_RE = re.compile(r"</?\s*[A-Za-z][^>]*>")

USER_FACING_LINE_RE = re.compile(
    r"NSLocalizedString|localized(?:Format)?\(|PasteBuddyLocalization\.(?:string|format)\(|"
    r"Text\(|Button\(|Label\(|LabeledContent\(|Toggle\(|Picker\(|Section\(|"
    r"Menu\(|TextField\(|ContentUnavailableView\(|\.help\(|accessibility(?:Label|Hint|Value)\(|"
    r"\.text\s*=|\.setTitle\("
)

IDENTITY_OK = {
    "Command",
    "Control",
    "MCP",
    "Option",
    "PasteBuddy",
    "Shift",
    "URL",
    "HTML",
    "brand.pastebuddy",
    "label.command",
    "label.control",
    "label.html",
    "label.mcp",
    "label.option",
    "label.shift",
    "label.url",
}

DEFAULT_GLOSSARY = {
    "PasteBuddy": "PasteBuddy",
    "Clipboard Shelf": "Clipboard Shelf",
    "Paste Stack": "Paste Stack",
    "Pinboard": "Pinboard",
    "Smart Pinboards": "Smart Pinboards",
    "Plain Text": "Plain Text",
    "Direct Paste": "Direct Paste",
    "MCP": "MCP",
    "CloudKit": "CloudKit",
    "Touch ID": "Touch ID",
    "URL": "URL",
}


@dataclass(frozen=True)
class StringsEntry:
    key: str
    value: str
    line: int


def unescape_strings_value(value: str) -> str:
    try:
        return json.loads(f'"{value}"')
    except json.JSONDecodeError:
        return (
            value.replace(r"\\", "\\")
            .replace(r"\"", '"')
            .replace(r"\n", "\n")
            .replace(r"\r", "\r")
            .replace(r"\t", "\t")
        )


def escape_strings_value(value: str) -> str:
    return (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\r", "\\r")
        .replace("\t", "\\t")
    )


def parse_strings(path: Path) -> list[StringsEntry]:
    entries: list[StringsEntry] = []
    for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        match = STRING_PAIR_RE.search(line)
        if not match:
            continue
        entries.append(
            StringsEntry(
                key=unescape_strings_value(match.group(1)),
                value=unescape_strings_value(match.group(2)),
                line=lineno,
            )
        )
    return entries


def entries_to_dict(entries: list[StringsEntry]) -> dict[str, str]:
    values: dict[str, str] = {}
    for entry in entries:
        values[entry.key] = entry.value
    return values


def should_skip_literal(line: str, literal: str, start: int) -> bool:
    if not literal.strip():
        return True
    if not re.search(r"[A-Za-z0-9]", literal):
        return True
    if r"\(" in literal:
        return True
    if literal.startswith("sf:"):
        return True
    prefix = line[max(0, start - 28) : start]
    if "defaultValue:" in prefix:
        return True
    if re.search(r"(systemImage|systemSymbolName|image|forType|keyEquivalent|name|id)\s*:\s*$", prefix):
        return True
    if re.fullmatch(r"[a-z0-9_.-]+", literal) and ("." in literal or literal.islower()):
        return True
    if re.fullmatch(r"[A-Za-z0-9_.-]{1,3}", literal):
        return True
    if literal.startswith("com."):
        return True
    if literal in {"source", "target", "custom", "true", "false"}:
        return True
    return False


def scan_swift_candidates() -> list[dict[str, Any]]:
    candidates: dict[str, dict[str, Any]] = {}
    roots = [
        ROOT / "Sources/PasteBuddy",
        ROOT / "Sources/PasteBuddyCore",
        ROOT / "Sources/PasteBuddyMobile",
        ROOT / "Sources/PasteBuddyiOS",
        ROOT / "Sources/PasteBuddyKeyboard",
        ROOT / "Sources/PasteBuddyShareAction",
    ]
    for source_root in roots:
        if not source_root.exists():
            continue
        for path in source_root.rglob("*.swift"):
            rel = path.relative_to(ROOT).as_posix()
            for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
                if not USER_FACING_LINE_RE.search(line):
                    continue
                default_value_matches = list(DEFAULT_VALUE_CALL_RE.finditer(line))
                if default_value_matches:
                    for match in default_value_matches:
                        key = unescape_strings_value(match.group(1))
                        source = unescape_strings_value(match.group(2))
                        candidates.setdefault(
                            key,
                            {
                                "key": key,
                                "source": source,
                                "context": f"{rel}:{lineno}",
                                "file": rel,
                                "line": lineno,
                            },
                        )
                    continue
                matches = list(LOCALIZED_CALL_RE.finditer(line))
                if not matches:
                    matches = list(STRING_LITERAL_RE.finditer(line))
                for match in matches:
                    literal = unescape_strings_value(match.group(1))
                    if should_skip_literal(line, literal, match.start()):
                        continue
                    candidates.setdefault(
                        literal,
                        {
                            "key": literal,
                            "source": literal,
                            "context": f"{rel}:{lineno}",
                            "file": rel,
                            "line": lineno,
                        },
                    )
    return sorted(candidates.values(), key=lambda item: (item["file"], item["line"], item["key"]))


def needs_translation(key: str, source: str, target: str | None, include_existing: bool) -> bool:
    if include_existing:
        return True
    if target is None:
        return True
    if not target.strip():
        return True
    if target == source and key not in IDENTITY_OK:
        return True
    return False


def build_payload(
    source_entries: list[StringsEntry],
    target_values: dict[str, str],
    include_existing: bool,
    include_code_candidates: bool,
) -> list[dict[str, Any]]:
    source_values = entries_to_dict(source_entries)
    items: dict[str, dict[str, Any]] = {}
    for entry in source_entries:
        if needs_translation(entry.key, entry.value, target_values.get(entry.key), include_existing):
            items[entry.key] = {
                "key": entry.key,
                "source": entry.value,
                "existing_target": target_values.get(entry.key),
                "context": f"Localizable.strings:{entry.line}",
                "file": DEFAULT_SOURCE.relative_to(ROOT).as_posix(),
                "line": entry.line,
            }
    if include_code_candidates:
        for candidate in scan_swift_candidates():
            key = candidate["key"]
            if key in source_values:
                continue
            items.setdefault(key, {**candidate, "existing_target": target_values.get(key)})
    return sorted(items.values(), key=lambda item: (item.get("file", ""), item.get("line", 0), item["key"]))


def load_api_key(env_name: str, secret_name: str, secret_project: str) -> str:
    value = os.environ.get(env_name)
    if value:
        return value.strip()
    command = [
        "gcloud",
        "secrets",
        "versions",
        "access",
        "latest",
        f"--secret={secret_name}",
        f"--project={secret_project}",
    ]
    completed = subprocess.run(command, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    return completed.stdout.strip()


def call_dify(url: str, api_key: str, items: list[dict[str, Any]], target_locale: str, mode: str) -> dict[str, Any]:
    request_body = {
        "inputs": {
            "payload": {"items": items},
            "target_locale": target_locale,
            "mode": mode,
            "glossary": DEFAULT_GLOSSARY,
        },
        "response_mode": "blocking",
        "user": "pastebuddy-localization-script",
    }
    request = urllib.request.Request(
        url,
        data=json.dumps(request_body).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=180) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Dify workflow failed with HTTP {error.code}: {body}") from error


def validate_translations(translations: list[dict[str, Any]]) -> list[str]:
    problems: list[str] = []
    for item in translations:
        key = str(item.get("key", ""))
        source = str(item.get("source", key))
        target = str(item.get("target", ""))
        if PLACEHOLDER_RE.findall(source) != PLACEHOLDER_RE.findall(target):
            problems.append(f"{key}: placeholder mismatch")
        if HTML_TAG_RE.findall(source) != HTML_TAG_RE.findall(target):
            problems.append(f"{key}: HTML tag mismatch")
        if not target.strip():
            problems.append(f"{key}: empty target")
    return problems


def chunked(items: list[dict[str, Any]], size: int) -> list[list[dict[str, Any]]]:
    return [items[index : index + size] for index in range(0, len(items), size)]


def apply_translations(
    source_path: Path,
    target_path: Path,
    translations: list[dict[str, Any]],
    source_values: dict[str, str],
    target_values: dict[str, str],
) -> tuple[int, int]:
    by_key = {str(item["key"]): str(item["target"]) for item in translations if item.get("key")}
    updated = 0
    appended = 0

    target_lines = target_path.read_text(encoding="utf-8").splitlines()
    new_lines: list[str] = []
    seen: set[str] = set()
    for line in target_lines:
        match = STRING_PAIR_RE.search(line)
        if not match:
            new_lines.append(line)
            continue
        key = unescape_strings_value(match.group(1))
        seen.add(key)
        if key in by_key and target_values.get(key) != by_key[key]:
            new_lines.append(f'"{escape_strings_value(key)}" = "{escape_strings_value(by_key[key])}";')
            updated += 1
        else:
            new_lines.append(line)

    source_lines = source_path.read_text(encoding="utf-8").splitlines()
    source_seen = {entry.key for entry in parse_strings(source_path)}
    source_append: list[str] = []
    target_append: list[str] = []
    for item in translations:
        key = str(item.get("key", ""))
        source = str(item.get("source", key))
        target = str(item.get("target", ""))
        if key not in source_seen:
            source_append.append(f'"{escape_strings_value(key)}" = "{escape_strings_value(source)}";')
            source_seen.add(key)
        if key not in seen:
            target_append.append(f'"{escape_strings_value(key)}" = "{escape_strings_value(target)}";')
            seen.add(key)
            appended += 1

    if source_append:
        if source_lines and source_lines[-1].strip():
            source_lines.append("")
        source_lines.extend(source_append)
        source_path.write_text("\n".join(source_lines) + "\n", encoding="utf-8")

    if target_append:
        if new_lines and new_lines[-1].strip():
            new_lines.append("")
        new_lines.extend(target_append)
    target_path.write_text("\n".join(new_lines) + "\n", encoding="utf-8")
    return updated, appended


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--target", type=Path, default=DEFAULT_TARGET)
    parser.add_argument("--target-locale", default="zh-Hans")
    parser.add_argument("--mode", choices=["scan", "translate", "apply"], default="scan")
    parser.add_argument("--workflow-mode", choices=["incremental", "full_app", "review_only"], default="incremental")
    parser.add_argument("--dify-url", default=DEFAULT_DIFY_URL)
    parser.add_argument("--api-key-env", default="DIFY_WORKFLOW_API_KEY")
    parser.add_argument("--secret-name", default=DEFAULT_SECRET_NAME)
    parser.add_argument("--secret-project", default=DEFAULT_SECRET_PROJECT)
    parser.add_argument("--chunk-size", type=int, default=40)
    parser.add_argument("--include-existing", action="store_true")
    parser.add_argument("--no-code-scan", action="store_true")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--input-result", type=Path, help="Use a prior translate result JSON instead of calling Dify.")
    args = parser.parse_args()

    source_entries = parse_strings(args.source)
    target_entries = parse_strings(args.target)
    source_values = entries_to_dict(source_entries)
    target_values = entries_to_dict(target_entries)
    items = build_payload(
        source_entries=source_entries,
        target_values=target_values,
        include_existing=args.include_existing,
        include_code_candidates=not args.no_code_scan,
    )

    if args.mode == "scan":
        print(json.dumps({"count": len(items), "items": items}, ensure_ascii=False, indent=2))
        return 0

    if args.input_result:
        result = json.loads(args.input_result.read_text(encoding="utf-8"))
        all_translations = result.get("translations") or []
        blocked_items = result.get("blocked") or []
        problems = result.get("local_problems") or validate_translations(all_translations)
    else:
        api_key = load_api_key(args.api_key_env, args.secret_name, args.secret_project)
        all_translations = []
        blocked_items = []
        qa_reports: list[dict[str, Any]] = []
        for batch in chunked(items, args.chunk_size):
            response = call_dify(args.dify_url, api_key, batch, args.target_locale, args.workflow_mode)
            outputs = response.get("data", {}).get("outputs", {})
            all_translations.extend(outputs.get("translations") or [])
            blocked_items.extend(outputs.get("blocked_items") or [])
            qa_reports.append(outputs.get("qa_report") or {})

        problems = validate_translations(all_translations)
        result = {
            "requested": len(items),
            "translated": len(all_translations),
            "blocked": blocked_items,
            "qa_reports": qa_reports,
            "local_problems": problems,
            "translations": all_translations,
        }
    if args.output:
        args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    else:
        print(json.dumps(result, ensure_ascii=False, indent=2))

    if blocked_items or problems:
        return 2

    if args.mode == "apply":
        updated, appended = apply_translations(
            args.source, args.target, all_translations, source_values, target_values
        )
        print(json.dumps({"updated": updated, "appended": appended}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
