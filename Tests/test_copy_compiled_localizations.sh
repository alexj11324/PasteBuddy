#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/pastebuddy-localizations.XXXXXX")"
trap 'rm -rf "$FIXTURE_ROOT"' EXIT

make_locales() {
  local root="$1"
  mkdir -p "$root/en.lproj" "$root/zh-Hans.lproj"
  printf '"label.general" = "General";\n' >"$root/en.lproj/Localizable.strings"
  printf '"label.general" = "通用";\n' >"$root/zh-Hans.lproj/Localizable.strings"
}

make_locales "$FIXTURE_ROOT/flat"
mkdir -p "$FIXTURE_ROOT/flat-output"
"$ROOT_DIR/script/copy_compiled_localizations.sh" \
  "$FIXTURE_ROOT/flat" \
  "$FIXTURE_ROOT/flat-output"
test -f "$FIXTURE_ROOT/flat-output/en.lproj/Localizable.strings"
test -f "$FIXTURE_ROOT/flat-output/zh-Hans.lproj/Localizable.strings"

make_locales "$FIXTURE_ROOT/xcode27/Contents/Resources"
mkdir -p "$FIXTURE_ROOT/xcode27-output"
"$ROOT_DIR/script/copy_compiled_localizations.sh" \
  "$FIXTURE_ROOT/xcode27" \
  "$FIXTURE_ROOT/xcode27-output"
test -f "$FIXTURE_ROOT/xcode27-output/en.lproj/Localizable.strings"
test -f "$FIXTURE_ROOT/xcode27-output/zh-Hans.lproj/Localizable.strings"

mkdir -p "$FIXTURE_ROOT/missing/en.lproj" "$FIXTURE_ROOT/missing-output"
printf '"label.general" = "General";\n' >"$FIXTURE_ROOT/missing/en.lproj/Localizable.strings"
if "$ROOT_DIR/script/copy_compiled_localizations.sh" \
  "$FIXTURE_ROOT/missing" \
  "$FIXTURE_ROOT/missing-output" >/dev/null 2>&1; then
  echo "Expected missing zh-Hans localization to fail" >&2
  exit 1
fi
