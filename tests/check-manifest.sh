#!/usr/bin/env bash
# robot.info drift guard (Sparks convention, 2026-07-05) — bash edition,
# matching this repo's no-runtime-beyond-stock-Linux rule.
# Compares robot.info's "version" to the newest CHANGELOG release heading.
# Run manually or from CI: tests/check-manifest.sh  (exit 0 = in sync)
set -euo pipefail
cd "$(dirname "$0")/.."

manifest_ver=$(sed 's|//.*||' robot.info | grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
changelog_ver=$(grep -m1 -E '^## v?[0-9]' CHANGELOG.md | sed -E 's/^## v?([0-9][^ ]*) .*/\1/')

if [ -z "$manifest_ver" ] || [ -z "$changelog_ver" ]; then
  echo "FAIL: could not extract versions (robot.info='$manifest_ver' CHANGELOG='$changelog_ver')" >&2
  exit 1
fi

if [ "$manifest_ver" != "$changelog_ver" ]; then
  echo "FAIL: robot.info says $manifest_ver but newest CHANGELOG release is $changelog_ver — update robot.info as part of the version bump." >&2
  exit 1
fi

echo "OK: robot.info $manifest_ver matches CHANGELOG $changelog_ver"
