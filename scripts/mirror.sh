#!/usr/bin/env bash
# Cut the public release repositories from this one.
#
# Usage:
#   ./scripts/mirror.sh [-b <branch>] [--tag] <remote-url>...
#
#   -b <branch>   branch to publish (default: main)
#   --tag         also tag the cut `v<version>` (version = npm/pngine/package.json)
#                 and push the tag. Refuses to move an existing tag.
#
# Exports HEAD to a temp dir, applies `.mirrorignore`, removes tests/ and
# strips the inline test blocks from every .zig file (zig-test-stripper), then
# commits the result ON TOP OF the previous cut and pushes it to every remote
# given. The public repositories therefore carry one commit per cut, in order,
# and no development history.
#
# The source is `git archive HEAD`, not the working tree. That is deliberate:
# a working-tree copy publishes untracked-but-unignored files, and it cannot
# see `.git/info/exclude`, which is the only thing hiding local index state
# and scratch files from the copy. Exporting HEAD means the cut carries
# exactly what a `git clone` of this repo would, minus the exclusions above,
# and it is reproducible from a commit id.
#
# The parent of the new commit is the branch tip of the FIRST remote that has
# one; the remotes are expected to be identical mirrors of each other. When
# the cut changes nothing (re-running for the same HEAD), no commit is made
# and `--tag` tags the existing tip.
#
# Requirements:
#   - zig (0.16.x+)
#   - zig-test-stripper source at ../zig-test-stripper (sibling directory)
#     or ZIG_TEST_STRIPPER_DIR env var pointing to its location

set -euo pipefail

BRANCH=main
TAG=0
REMOTES=()
while [ $# -gt 0 ]; do
    case "$1" in
        -b) BRANCH="${2:?-b needs a branch name}"; shift 2 ;;
        --tag) TAG=1; shift ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        -*) echo "error: unknown option $1" >&2; exit 2 ;;
        *) REMOTES+=("$1"); shift ;;
    esac
done
if [ ${#REMOTES[@]} -eq 0 ]; then
    echo "Usage: $0 [-b <branch>] [--tag] <remote-url>..." >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STRIPPER_DIR="${ZIG_TEST_STRIPPER_DIR:-$PROJECT_DIR/../zig-test-stripper}"
IGNOREFILE="$PROJECT_DIR/.mirrorignore"

VERSION="$(sed -n 's/^  "version": "\(.*\)",$/\1/p' "$PROJECT_DIR/npm/pngine/package.json" | head -1)"
if [ -z "$VERSION" ]; then
    echo "error: could not read the version from npm/pngine/package.json" >&2
    exit 1
fi

# --- Validate zig-test-stripper is available ---
if [ ! -f "$STRIPPER_DIR/build.zig" ]; then
    echo "error: zig-test-stripper not found at $STRIPPER_DIR"
    echo "Set ZIG_TEST_STRIPPER_DIR or clone it as a sibling directory."
    exit 1
fi

# --- Build zig-test-stripper ---
echo "Building zig-test-stripper..."
(cd "$STRIPPER_DIR" && zig build -Doptimize=ReleaseFast)
STRIPPER="$STRIPPER_DIR/zig-out/bin/zig-test-stripper"

if [ ! -x "$STRIPPER" ]; then
    echo "error: zig-test-stripper binary not found after build"
    exit 1
fi

# --- Export HEAD to temp directory ---
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

HEAD_SHA="$(git -C "$PROJECT_DIR" rev-parse --short HEAD)"
if ! git -C "$PROJECT_DIR" diff-index --quiet HEAD --; then
    echo "note: working tree is dirty — cutting HEAD ($HEAD_SHA), uncommitted changes excluded."
fi

echo "Exporting HEAD ($HEAD_SHA) to temporary directory..."
mkdir -p "$TMP/head"
git -C "$PROJECT_DIR" archive HEAD | tar -x -C "$TMP/head"

# .mirrorignore is applied as a second pass rather than as `git archive`
# pathspecs, so it keeps rsync exclude-pattern semantics (trailing-slash dirs,
# globs) instead of gitattributes' export-ignore.
RSYNC_EXTRA=()
if [ -f "$IGNOREFILE" ]; then
    echo "Using .mirrorignore for additional exclusions..."
    RSYNC_EXTRA+=(--exclude-from="$IGNOREFILE")
fi

mkdir -p "$TMP/repo"
rsync -a "${RSYNC_EXTRA[@]}" "$TMP/head/" "$TMP/repo/"

cd "$TMP/repo"
git init --quiet
git checkout -b "$BRANCH" --quiet

# --- Remove test directories and files ---
echo "Removing tests/..."
rm -rf tests/

echo "Removing *_test.zig and */test.zig files..."
find . -name '*_test.zig' -delete
find . -path '*/test.zig' -not -path './src/*/main.zig' -delete

echo "Removing JS/TS test files..."
find . -name '*.test.js' -delete
find . -name '*.test.ts' -delete
find . -name '*.spec.js' -delete
rm -f playwright.config.js

# --- Strip inline test blocks from .zig files ---
echo "Stripping inline tests from .zig files..."
find . -name '*.zig' -type f | while read -r f; do
    "$STRIPPER" -i "$f"
done

# --- Chain onto the previous cut, if any remote has one ---
PARENT=""
for remote in "${REMOTES[@]}"; do
    if git fetch --quiet "$remote" "$BRANCH" 2>/dev/null; then
        PARENT="$(git rev-parse FETCH_HEAD)"
        echo "Previous cut found on $remote: ${PARENT:0:7}"
        break
    fi
done
if [ -n "$PARENT" ]; then
    # HEAD + index = previous cut, working tree = new cut; the commit records
    # the delta between them.
    git reset --quiet "$PARENT"
fi

# --- Stage and commit ---
git add -A
if [ -n "$PARENT" ] && git diff --cached --quiet; then
    echo "The cut is identical to the previous one — no new commit."
    CUT="$PARENT"
else
    # `git init` in a temp dir picks up GLOBAL config, and a global
    # `commit.gpgsign=true` kills the script here ("agent refused operation")
    # even though this repo disables signing locally. The cut is a synthetic
    # squash; signing it would attest to nothing.
    git -c commit.gpgsign=false commit --quiet -F - <<EOF
pngine $VERSION

Release cut of development commit $HEAD_SHA: the engine source and
reference docs, without the test suite.
EOF
    CUT="$(git rev-parse HEAD)"
fi

# --- Push ---
for remote in "${REMOTES[@]}"; do
    echo "Pushing $BRANCH to $remote..."
    git push --quiet "$remote" "$BRANCH"
done

if [ "$TAG" = 1 ]; then
    TAGNAME="v$VERSION"
    git -c tag.gpgsign=false tag -a "$TAGNAME" -m "pngine $VERSION" "$CUT"
    for remote in "${REMOTES[@]}"; do
        # An annotated tag's peeled ref is the commit it names.
        existing="$(git ls-remote --tags "$remote" "refs/tags/$TAGNAME^{}" | cut -f1)"
        if [ -z "$existing" ]; then
            echo "Pushing $TAGNAME to $remote..."
            git push --quiet "$remote" "$TAGNAME"
        elif [ "$existing" = "$CUT" ]; then
            echo "$TAGNAME already names this cut on $remote."
        else
            echo "error: $TAGNAME exists on $remote at ${existing:0:7}, not ${CUT:0:7} — refusing to move it." >&2
            exit 1
        fi
    done
fi

echo "Done. pngine $VERSION cut ${CUT:0:7} (from $HEAD_SHA) is on: ${REMOTES[*]}"
