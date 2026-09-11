#!/usr/bin/env bash
# Print one version's release notes: the body of its `## [<version>]` section
# in CHANGELOG.md, without the heading.
#
# Usage:
#   ./scripts/release-notes.sh [<version>]   (default: npm/pngine/package.json's)
#
# scripts/mirror.sh puts this text in the release cut's commit message, in the
# `v<version>` tag annotation and in the GitHub Release. It exits 1 when the
# section is missing or holds only whitespace, so a cut cannot go out with
# blank notes.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHANGELOG="$ROOT/CHANGELOG.md"

VERSION="${1:-$(sed -n 's/^  "version": "\(.*\)",$/\1/p' "$ROOT/npm/pngine/package.json" | head -1)}"
if [ -z "$VERSION" ]; then
    echo "error: no version given and none readable from npm/pngine/package.json" >&2
    exit 1
fi

# From the line after `## [<version>]` up to the next `## [` heading. The
# heading is matched as a literal prefix, so the dots in a version are dots.
NOTES="$(awk -v heading="## [$VERSION]" '
    /^## \[/ { if (inside) exit; inside = (index($0, heading) == 1); next }
    inside
' "$CHANGELOG" | sed '/./,$!d')"

if [ -z "$(printf '%s' "$NOTES" | tr -d '[:space:]')" ]; then
    echo "error: CHANGELOG.md has no notes under '## [$VERSION]'" >&2
    exit 1
fi

printf '%s\n' "$NOTES"
