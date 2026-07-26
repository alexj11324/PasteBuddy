#!/usr/bin/env python3
"""Maintain and validate PasteBuddy's authoritative String Catalog."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RESOURCE_ROOT = ROOT / "Sources/PasteBuddy/Resources"
STRING_CATALOG = RESOURCE_ROOT / "Localizable.xcstrings"
XCODE_PROJECT = ROOT / "PasteBuddyiOS.xcodeproj/project.pbxproj"

LOCALES = ("en", "zh-Hans")
SEMANTIC_PREFIXES = {
    "action",
    "automation",
    "brand",
    "dialog",
    "format",
    "label",
    "message",
    "mobile",
    "mcp",
    "state",
    "value",
}

STRING_LITERAL_RE = re.compile(r'"((?:\\.|[^"\\])*)"')
PLACEHOLDER_RE = re.compile(r"%(?:\d+\$)?(?:lld|llu|ld|lu|@|[diuoxXfFeEgGcCsSpaA])")

USER_FACING_LINE_RE = re.compile(
    r"NSLocalizedString|String\(localized:|localized(?:Format)?\(|PasteBuddyLocalization\.(?:string|format)\(|"
    r"Text\(|Button\(|Label\(|LabeledContent\(|"
    r"Toggle\(|Picker\(|Section\(|Menu\(|TextField\(|ContentUnavailableView\(|"
    r"\.help\(|accessibility(?:Label|Hint|Value)\(|setAccessibilityLabel\(|"
    r"accessibilityDescription:|\.text\s*=|\.setTitle\("
)
DEFAULT_VALUE_CALL_RE = re.compile(
    r"(?:PasteBuddyLocalization\.(?:string|format)|localized(?:Format)?)"
    r"\(\s*\"((?:\\.|[^\"\\])*)\"\s*,\s*defaultValue:\s*\"((?:\\.|[^\"\\])*)\""
)
KEYED_LOCALIZATION_CALL_RE = re.compile(
    r"(?:NSLocalizedString|localized(?:Format)?|PasteBuddyLocalization\.(?:string|format))"
    r"\(\s*\"((?:\\.|[^\"\\])*)\""
)

SOURCE_ROOTS = [
    ROOT / "Sources/PasteBuddy",
    ROOT / "Sources/PasteBuddyCore",
    ROOT / "Sources/PasteBuddyMobile",
    ROOT / "Sources/PasteBuddyiOS",
    ROOT / "Sources/PasteBuddyKeyboard",
    ROOT / "Sources/PasteBuddyShareAction",
]


@dataclass(frozen=True)
class CatalogEntry:
    canonical_key: str
    legacy_key: str
    english: str
    simplified_chinese: str


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


def is_semantic_key(key: str) -> bool:
    if not re.fullmatch(r"[a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+", key):
        return False
    return key.split(".", 1)[0] in SEMANTIC_PREFIXES


def build_catalog_entries(payload: dict[str, object]) -> list[CatalogEntry]:
    strings = payload.get("strings")
    if not isinstance(strings, dict):
        return []
    entries: list[CatalogEntry] = []
    for key, raw_entry in strings.items():
        english = localized_value(raw_entry, "en")
        simplified_chinese = localized_value(raw_entry, "zh-Hans")
        if english is None or simplified_chinese is None:
            continue
        canonical_key = key
        if not is_semantic_key(key) and isinstance(raw_entry, dict):
            comment = raw_entry.get("comment")
            if isinstance(comment, str):
                match = re.search(r"Legacy alias for ([a-z0-9_.]+)\.", comment)
                if match:
                    canonical_key = match.group(1)
        entries.append(
            CatalogEntry(
                canonical_key=canonical_key,
                legacy_key=key,
                english=english,
                simplified_chinese=simplified_chinese,
            )
        )
    return sorted(entries, key=lambda item: (item.canonical_key, item.legacy_key))


def replacement_map(entries: list[CatalogEntry]) -> dict[str, str]:
    return {
        entry.legacy_key: entry.canonical_key
        for entry in entries
        if entry.legacy_key != entry.canonical_key
    }


def should_rewrite_line(path: Path, line: str) -> bool:
    return bool(USER_FACING_LINE_RE.search(line))


def should_skip_literal(line: str, start: int) -> bool:
    prefix = line[max(0, start - 36) : start]
    literal_prefix = line[max(0, start - 3) : start]
    if literal_prefix == r"\(":
        return True
    if "defaultValue:" in prefix:
        return True
    if re.search(r"(systemImage|systemName|systemSymbolName)\s*:", line[:start]):
        return True
    if re.search(r"(systemImage|systemSymbolName|image|forType|keyEquivalent|name|id)\s*:\s*$", prefix):
        return True
    if "sourceAppName:" in prefix or "sourceBundleIdentifier:" in prefix:
        return True
    return False


def should_skip_raw_literal(literal: str, line: str, start: int) -> bool:
    if should_skip_literal(line, start):
        return True
    if not literal.strip():
        return True
    if r"\(" in literal:
        return True
    if not re.search(r"[A-Za-z]", literal):
        return True
    if literal.startswith("com."):
        return True
    if re.fullmatch(r"[A-Za-z0-9_.-]{1,3}", literal):
        return True
    if re.fullmatch(r"[a-z0-9]+(?:\.[a-z0-9]+)+", literal) and not is_semantic_key(literal):
        return True
    return False


def rewrite_line_literals(line: str, replacements: dict[str, str]) -> str:
    def replace(match: re.Match[str]) -> str:
        literal = unescape_strings_value(match.group(1))
        if literal not in replacements or should_skip_literal(line, match.start()):
            return match.group(0)
        return f'"{escape_strings_value(replacements[literal])}"'

    return STRING_LITERAL_RE.sub(replace, line)


def rewrite_swift_sources(entries: list[CatalogEntry]) -> int:
    replacements = replacement_map(entries)
    changed = 0
    paths: list[Path] = []
    for root in SOURCE_ROOTS:
        if root.exists():
            paths.extend(sorted(root.rglob("*.swift")))
    for path in paths:
        original = path.read_text(encoding="utf-8")
        new_lines: list[str] = []
        did_change = False
        for line in original.splitlines():
            if should_rewrite_line(path, line):
                rewritten = rewrite_line_literals(line, replacements)
                if rewritten != line:
                    did_change = True
                new_lines.append(rewritten)
            else:
                new_lines.append(line)
        if did_change:
            path.write_text("\n".join(new_lines) + "\n", encoding="utf-8")
            changed += 1
    return changed


def validate_catalog_shape(problems: list[str]) -> dict[str, object] | None:
    if not STRING_CATALOG.exists():
        problems.append(f"Missing {STRING_CATALOG.relative_to(ROOT)}")
        return None
    try:
        payload = json.loads(STRING_CATALOG.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        problems.append(f"{STRING_CATALOG.relative_to(ROOT)} is invalid JSON: {error}")
        return None
    if payload.get("sourceLanguage") != "en":
        problems.append("Localizable.xcstrings sourceLanguage must be en")
    if payload.get("version") != "1.0":
        problems.append("Localizable.xcstrings version must be 1.0")
    if not isinstance(payload.get("strings"), dict):
        problems.append("Localizable.xcstrings strings must be an object")
    return payload


def localized_value(catalog_entry: object, locale: str) -> str | None:
    if not isinstance(catalog_entry, dict):
        return None
    localizations = catalog_entry.get("localizations")
    if not isinstance(localizations, dict):
        return None
    locale_payload = localizations.get(locale)
    if not isinstance(locale_payload, dict):
        return None
    string_unit = locale_payload.get("stringUnit")
    if not isinstance(string_unit, dict):
        return None
    value = string_unit.get("value")
    return value if isinstance(value, str) else None


def validate_single_catalog_authority(problems: list[str]) -> None:
    legacy_resources = sorted(RESOURCE_ROOT.rglob("Localizable.strings"))
    if legacy_resources:
        paths = ", ".join(str(path.relative_to(ROOT)) for path in legacy_resources)
        problems.append(f"Localizable.xcstrings must be the only app localization source; remove {paths}")
    package_manifest = (ROOT / "Package.swift").read_text(encoding="utf-8")
    if "Localizable.strings" in package_manifest:
        problems.append("Package.swift must not process or exclude duplicate Localizable.strings resources")


def validate_catalog_values(payload: dict[str, object] | None, problems: list[str]) -> None:
    if payload is None:
        return
    strings = payload.get("strings")
    if not isinstance(strings, dict):
        return
    for key in sorted(strings):
        english_value = localized_value(strings[key], "en")
        chinese_value = localized_value(strings[key], "zh-Hans")
        if english_value is None:
            problems.append(f"{key}: missing en stringUnit")
            continue
        if chinese_value is None:
            problems.append(f"{key}: missing zh-Hans stringUnit")
            continue
        if not chinese_value.strip():
            problems.append(f"{key}: empty zh-Hans catalog value")
        if PLACEHOLDER_RE.findall(english_value) != PLACEHOLDER_RE.findall(chinese_value):
            problems.append(f"{key}: placeholder mismatch in catalog")
        if not is_semantic_key(key):
            catalog_entry = strings[key]
            if not isinstance(catalog_entry, dict) or "Legacy alias for" not in str(catalog_entry.get("comment", "")):
                problems.append(f"{key}: non-semantic catalog key must be marked as a legacy alias")


def validate_project_membership(problems: list[str]) -> None:
    if not XCODE_PROJECT.exists():
        problems.append("Missing PasteBuddyiOS.xcodeproj/project.pbxproj")
        return
    project = XCODE_PROJECT.read_text(encoding="utf-8")
    catalog_resource_count = project.count("Localizable.xcstrings in Resources")
    if catalog_resource_count < 4:
        problems.append("Localizable.xcstrings must be included in all four iOS target resource phases")
    if "Localizable.strings" in project:
        problems.append("Xcode project must not reference duplicate Localizable.strings resources")
    if "text.json.xcstrings" not in project or "Sources/PasteBuddy/Resources/Localizable.xcstrings" not in project:
        problems.append("Xcode project is missing the Localizable.xcstrings file reference")


def validate_catalog_compiles(problems: list[str]) -> None:
    tmp_root = ROOT / "tmp"
    tmp_root.mkdir(exist_ok=True)
    try:
        with tempfile.TemporaryDirectory(prefix="localization-xcstringstool-", dir=tmp_root) as output_dir:
            result = subprocess.run(
                [
                    "xcrun",
                    "xcstringstool",
                    "compile",
                    str(STRING_CATALOG),
                    "--output-directory",
                    output_dir,
                    "--language",
                    "en",
                    "--language",
                    "zh-Hans",
                    "--serialization-format",
                    "text",
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
                timeout=30,
                check=False,
            )
    except FileNotFoundError:
        problems.append("xcrun is not available; cannot compile Localizable.xcstrings")
        return
    except subprocess.TimeoutExpired:
        problems.append("xcstringstool timed out while compiling Localizable.xcstrings")
        return
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        problems.append(f"xcstringstool failed to compile Localizable.xcstrings: {detail or result.returncode}")


def validate_swift_call_sites(entries: list[CatalogEntry], problems: list[str]) -> None:
    replacements = replacement_map(entries)
    known_keys = {entry.canonical_key for entry in entries} | {entry.legacy_key for entry in entries}
    english_by_key = {entry.canonical_key: entry.english for entry in entries}
    english_by_key.update({entry.legacy_key: entry.english for entry in entries})
    for root in SOURCE_ROOTS:
        if not root.exists():
            continue
        for path in sorted(root.rglob("*.swift")):
            for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
                if not should_rewrite_line(path, line):
                    continue
                rel = path.relative_to(ROOT)
                for match in DEFAULT_VALUE_CALL_RE.finditer(line):
                    key = unescape_strings_value(match.group(1))
                    default_value = unescape_strings_value(match.group(2))
                    if key not in known_keys:
                        problems.append(f"{rel}:{lineno}: localization key {key!r} is missing from Localizable resources")
                        continue
                    expected = english_by_key.get(key)
                    if expected is not None and expected != default_value:
                        problems.append(
                            f"{rel}:{lineno}: defaultValue for {key!r} must match English catalog value {expected!r}"
                        )
                for match in KEYED_LOCALIZATION_CALL_RE.finditer(line):
                    key = unescape_strings_value(match.group(1))
                    if is_semantic_key(key) and key not in known_keys:
                        problems.append(f"{rel}:{lineno}: localization key {key!r} is missing from Localizable resources")
                if r"\(" in line:
                    continue
                for match in STRING_LITERAL_RE.finditer(line):
                    literal = unescape_strings_value(match.group(1))
                    if literal in replacements and not should_skip_literal(line, match.start()):
                        problems.append(
                            f"{rel}:{lineno}: use semantic key {replacements[literal]!r} instead of {literal!r}"
                        )
                        continue
                    if should_skip_raw_literal(literal, line, match.start()):
                        continue
                    if is_semantic_key(literal):
                        if literal not in known_keys:
                            problems.append(f"{rel}:{lineno}: localization key {literal!r} is missing from Localizable resources")
                        continue
                    problems.append(f"{rel}:{lineno}: user-facing literal {literal!r} must use a semantic localization key")


def run_sync(rewrite_swift: bool) -> int:
    payload = json.loads(STRING_CATALOG.read_text(encoding="utf-8"))
    entries = build_catalog_entries(payload)
    changed_sources = rewrite_swift_sources(entries) if rewrite_swift else 0
    print(
        json.dumps(
            {
                "semantic_keys": len({entry.canonical_key for entry in entries}),
                "legacy_aliases": len([entry for entry in entries if entry.legacy_key != entry.canonical_key]),
                "rewritten_swift_files": changed_sources,
                "catalog": str(STRING_CATALOG.relative_to(ROOT)),
            },
            indent=2,
            sort_keys=True,
        )
    )
    return 0


def run_check() -> int:
    problems: list[str] = []
    payload = validate_catalog_shape(problems)
    entries = build_catalog_entries(payload) if payload is not None else []
    validate_single_catalog_authority(problems)
    validate_catalog_values(payload, problems)
    validate_project_membership(problems)
    validate_catalog_compiles(problems)
    validate_swift_call_sites(entries, problems)
    if problems:
        for problem in problems:
            print(f"error: {problem}", file=sys.stderr)
        return 1
    print(
        json.dumps(
            {
                "status": "ok",
                "semantic_keys": len({entry.canonical_key for entry in entries}),
                "catalog_keys": len(json.loads(STRING_CATALOG.read_text(encoding="utf-8"))["strings"]),
            },
            indent=2,
            sort_keys=True,
        )
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    sync_parser = subparsers.add_parser("sync", help="Rewrite Swift call sites from catalog aliases.")
    sync_parser.add_argument("--rewrite-swift", action="store_true", help="Rewrite localized Swift literals to semantic keys.")
    subparsers.add_parser("check", help="Validate the String Catalog workflow.")
    args = parser.parse_args()

    if args.command == "sync":
        return run_sync(args.rewrite_swift)
    if args.command == "check":
        return run_check()
    parser.error(f"Unsupported command {args.command}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
