#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 <iroh-static-archive> [maximum-macos-version]" >&2
  exit 2
}

[[ $# -ge 1 && $# -le 2 ]] || usage

archive="$1"
maximum_version="${2:-14.5}"

[[ -f "$archive" ]] || {
  echo "Iroh macOS archive is missing: $archive" >&2
  exit 1
}
[[ "$maximum_version" =~ ^[0-9]+([.][0-9]+){0,2}$ ]] || {
  echo "Invalid maximum macOS version: $maximum_version" >&2
  exit 2
}

otool_path="$(xcrun --find otool)"

"$otool_path" -l "$archive" | /usr/bin/awk -v maximum="$maximum_version" '
function version_greater(lhs, rhs, left, right, left_count, right_count, count, part, left_value, right_value) {
  left_count = split(lhs, left, ".")
  right_count = split(rhs, right, ".")
  count = left_count > right_count ? left_count : right_count
  for (part = 1; part <= count; part++) {
    left_value = part <= left_count ? left[part] + 0 : 0
    right_value = part <= right_count ? right[part] + 0 : 0
    if (left_value > right_value) return 1
    if (left_value < right_value) return 0
  }
  return 0
}

function record_version(version) {
  object_count++
  version_counts[version]++
  if (version_greater(version, maximum)) {
    violation_count++
    printf "Iroh release compatibility violation: %s has minOS %s (maximum %s)\n", member, version, maximum > "/dev/stderr"
  }
}

/\):$/ {
  member = $0
  sub(/^.*\(/, "", member)
  sub(/\):$/, "", member)
}

$1 == "cmd" && $2 == "LC_BUILD_VERSION" {
  expected_field = "minos"
  next
}

$1 == "cmd" && $2 == "LC_VERSION_MIN_MACOSX" {
  expected_field = "version"
  next
}

expected_field == "minos" && $1 == "minos" {
  record_version($2)
  expected_field = ""
  next
}

expected_field == "version" && $1 == "version" {
  record_version($2)
  expected_field = ""
  next
}

END {
  if (object_count == 0) {
    print "Iroh release compatibility check found no macOS Mach-O objects" > "/dev/stderr"
    exit 2
  }

  for (version in version_counts) {
    printf "Iroh macOS objects with minOS %s: %d\n", version, version_counts[version]
  }

  if (violation_count > 0) {
    printf "Iroh macOS release blocked: %d object(s) require newer than macOS %s. Upgrade to an upstream artifact that passes this check; do not suppress the linker warning.\n", violation_count, maximum > "/dev/stderr"
    exit 1
  }
}
'

echo "Iroh macOS minimum-OS compatibility verified: $archive (maximum $maximum_version)"
