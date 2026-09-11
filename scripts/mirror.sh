#!/usr/bin/env bash
# Cut the public release repositories from this one.
#
# Usage:
#   ./scripts/mirror.sh [-b <branch>] [--tag [--gh-release]] <remote-url>...
#
#   -b <branch>    branch to publish (default: main)
#   --tag          also tag the cut `v<version>` (version = npm/pngine/package.json)
#                  and push the tag. Refuses to move an existing tag.
#   --gh-release   once the tag is pushed, create a GitHub Release for it on
#                  every github.com remote given. Needs --tag and a `gh` logged
#                  in to github.com; a release that already exists is left alone.
#
# Exports HEAD to a temp dir, applies `.mirrorignore`, removes tests/ and
# strips the inline test blocks from every .zig file (zig-test-stripper), then
# commits the result ON TOP OF the previous cut and pushes it to every remote
# given. The public repositories therefore carry one commit per cut, in order,
# and no development history.
#
# The cut carries its release notes. The version's section of CHANGELOG.md
# (scripts/release-notes.sh) is the body of the cut commit, of the tag
# annotation and of the GitHub Release. A version with no section, or an empty
# one, stops the script before anything is built or pushed.
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
#   - gh, for --gh-release only

set -euo pipefail

BRANCH=main
TAG=0
GH_RELEASE=0
REMOTES=()
while [ $# -gt 0 ]; do
    case "$1" in
        -b) BRANCH="${2:?-b needs a branch name}"; shift 2 ;;
        --tag) TAG=1; shift ;;
        --gh-release) GH_RELEASE=1; shift ;;
        -h|--help) sed -n '2,/^[^#]/p' "$0" | sed '$d'; exit 0 ;;
        -*) echo "error: unknown option $1" >&2; exit 2 ;;
        *) REMOTES+=("$1"); shift ;;
    esac
done
if [ ${#REMOTES[@]} -eq 0 ]; then
    echo "Usage: $0 [-b <branch>] [--tag [--gh-release]] <remote-url>..." >&2
    exit 2
fi
if [ "$GH_RELEASE" = 1 ] && [ "$TAG" = 0 ]; then
    echo "error: --gh-release needs --tag, since a release is made from a pushed tag" >&2
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

# --- Release notes: this version's CHANGELOG.md section ---
# Read from the working tree's CHANGELOG.md, which must match HEAD's for the
# notes to describe the cut; a dirty CHANGELOG.md is refused for that reason.
if ! git -C "$PROJECT_DIR" diff --quiet HEAD -- CHANGELOG.md; then
    echo "error: CHANGELOG.md has uncommitted changes; the notes must be the committed ones" >&2
    exit 1
fi
NOTES="$("$SCRIPT_DIR/release-notes.sh" "$VERSION")"

# --- GitHub Release preconditions, checked before anything is pushed ---
GH_REPOS=()
if [ "$GH_RELEASE" = 1 ]; then
    for remote in "${REMOTES[@]}"; do
        # git@github.com:OWNER/REPO(.git), ssh://git@github.com/..., https://github.com/...
        slug="$(printf '%s\n' "$remote" \
            | sed -n -E 's#^(git@github\.com:|ssh://git@github\.com/|https://github\.com/)([^/]+/[^/]+)$#\2#p' \
            | sed 's/\.git$//')"
        if [ -n "$slug" ]; then
            GH_REPOS+=("$slug")
        fi
    done
    if [ ${#GH_REPOS[@]} -eq 0 ]; then
        echo "error: --gh-release given, but no remote is on github.com" >&2
        exit 2
    fi
    if ! command -v gh >/dev/null 2>&1 || ! gh auth status --hostname github.com >/dev/null 2>&1; then
        echo "error: --gh-release needs gh logged in to github.com (gh auth login)" >&2
        exit 1
    fi
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
# `--cleanup=whitespace` keeps the notes' `### Added` headings, which the
# default `strip` mode would delete as comment lines.
git add -A
if [ -n "$PARENT" ] && git diff --cached --quiet; then
    echo "The cut is identical to the previous one — no new commit."
    CUT="$PARENT"
else
    # `git init` in a temp dir picks up GLOBAL config, and a global
    # `commit.gpgsign=true` kills the script here ("agent refused operation")
    # even though this repo disables signing locally. The cut is a synthetic
    # squash; signing it would attest to nothing.
    git -c commit.gpgsign=false commit --quiet --cleanup=whitespace -F - <<EOF
pngine $VERSION

Release cut of development commit $HEAD_SHA: the engine source and
reference docs, without the test suite.

$NOTES
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
    printf 'pngine %s\n\n%s\n' "$VERSION" "$NOTES" > "$TMP/tag-message"
    git -c tag.gpgsign=false tag -a --cleanup=whitespace -F "$TMP/tag-message" "$TAGNAME" "$CUT"
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

if [ "$GH_RELEASE" = 1 ]; then
    printf '%s\n' "$NOTES" > "$TMP/release-notes.md"
    for repo in "${GH_REPOS[@]}"; do
        if gh release view "$TAGNAME" --repo "$repo" >/dev/null 2>&1; then
            echo "GitHub Release $TAGNAME already exists on $repo, left as it is."
        else
            echo "Creating GitHub Release $TAGNAME on $repo..."
            gh release create "$TAGNAME" --repo "$repo" --verify-tag \
                --title "pngine $VERSION" --notes-file "$TMP/release-notes.md"
        fi
    done
fi

echo "Done. pngine $VERSION cut ${CUT:0:7} (from $HEAD_SHA) is on: ${REMOTES[*]}"
