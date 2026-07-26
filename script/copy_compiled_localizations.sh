#!/usr/bin/env bash
set -euo pipefail

RESOURCE_BUNDLE="${1:?resource bundle path is required}"
APP_RESOURCES="${2:?app resources path is required}"

[[ -d "$RESOURCE_BUNDLE" ]] || {
  echo "Missing SwiftPM resource bundle: $RESOURCE_BUNDLE" >&2
  exit 1
}

RESOURCE_ROOT="$RESOURCE_BUNDLE"
if [[ -d "$RESOURCE_BUNDLE/Contents/Resources" ]]; then
  RESOURCE_ROOT="$RESOURCE_BUNDLE/Contents/Resources"
fi

for locale in en zh-Hans; do
  localization_dir="$RESOURCE_ROOT/$locale.lproj"
  [[ -f "$localization_dir/Localizable.strings" ]] || {
    echo "Missing compiled $locale localization: $localization_dir/Localizable.strings" >&2
    exit 1
  }
  /usr/bin/ditto --norsrc --noextattr "$localization_dir" "$APP_RESOURCES/$locale.lproj"
done
