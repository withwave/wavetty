#!/usr/bin/env bash
# End-to-end Wavetty release pipeline.
#
#   1. Rebase current branch on upstream/main
#   2. Build + sign + notarize DMG (delegates to build-wavetty.sh --release)
#   3. Create or update GitHub Release (asset = DMG)
#   4. Tag the commit + push branch and tag to origin
#
# Usage:
#   scripts/release-wavetty.sh
#       Use the version in VERSION file, create release if missing.
#
#   scripts/release-wavetty.sh --bump 1.3.3-withwave
#       Write that version to VERSION first, commit it, then release.
#
#   scripts/release-wavetty.sh --skip-rebase
#       Skip the upstream rebase step (useful for re-releasing same code).
#
# Requires:
#   * Clean working tree
#   * `upstream` remote pointing at ghostty-org/ghostty
#   * `origin` remote pointing at withwave/ghostty
#   * `gh` authenticated to GitHub
#   * notarytool keychain profile (see RELEASING-WITHWAVE.md)

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
UPSTREAM_REMOTE="upstream"
UPSTREAM_BRANCH="main"
ORIGIN_REMOTE="origin"
ORIGIN_BRANCH="main"
GITHUB_REPO="withwave/ghostty"

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
NEW_VERSION=""
SKIP_REBASE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --bump)       shift; NEW_VERSION="$1" ;;
        --skip-rebase) SKIP_REBASE=1 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
if [ -n "$(git status --porcelain)" ]; then
    echo "ERROR: working tree is not clean. Commit or stash first."
    git status --short
    exit 1
fi

if ! git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1; then
    echo "ERROR: '$UPSTREAM_REMOTE' remote not configured."
    echo "  git remote add upstream https://github.com/ghostty-org/ghostty.git"
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 1: Rebase
# ---------------------------------------------------------------------------
if [ "$SKIP_REBASE" -eq 0 ]; then
    echo "==> Step 1: Fetch + rebase on $UPSTREAM_REMOTE/$UPSTREAM_BRANCH"
    git fetch "$UPSTREAM_REMOTE"
    PRE=$(git rev-parse HEAD)
    if ! git rebase "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"; then
        echo ""
        echo "ERROR: rebase conflicts. Resolve manually, then run:"
        echo "  git rebase --continue"
        echo "  scripts/release-wavetty.sh --skip-rebase"
        exit 1
    fi
    POST=$(git rev-parse HEAD)
    if [ "$PRE" = "$POST" ]; then
        echo "    Already up to date with upstream."
    else
        echo "    Rebased onto upstream. New HEAD: $POST"
    fi
else
    echo "==> Step 1: Rebase skipped (--skip-rebase)"
fi

# ---------------------------------------------------------------------------
# Step 2: Version bump (optional)
# ---------------------------------------------------------------------------
if [ -n "$NEW_VERSION" ]; then
    echo "==> Step 2: Bump VERSION to $NEW_VERSION"
    echo "$NEW_VERSION" > VERSION
    git add VERSION
    git commit -m "chore: bump version to $NEW_VERSION"
fi

VERSION="$(cat VERSION)"
TAG="v${VERSION}"
echo "    Version: $VERSION"
echo "    Tag    : $TAG"

# ---------------------------------------------------------------------------
# Step 3: Build + sign + notarize
# ---------------------------------------------------------------------------
echo "==> Step 3: Build + sign + DMG + notarize"
./scripts/build-wavetty.sh --dmg
DMG="$ROOT/zig-out/Wavetty.dmg"
[ -f "$DMG" ] || { echo "ERROR: DMG not produced at $DMG"; exit 1; }

# ---------------------------------------------------------------------------
# Step 4: Create or update GitHub Release
# ---------------------------------------------------------------------------
echo "==> Step 4: GitHub Release $TAG"
if gh release view "$TAG" --repo "$GITHUB_REPO" >/dev/null 2>&1; then
    echo "    Release exists. Replacing DMG asset."
    gh release upload "$TAG" "$DMG" --repo "$GITHUB_REPO" --clobber
else
    echo "    Creating new release."
    gh release create "$TAG" "$DMG" --repo "$GITHUB_REPO" \
        --title "Wavetty $VERSION" \
        --notes "Wavetty $VERSION release. See commit log for changes."
fi

# ---------------------------------------------------------------------------
# Step 5: Tag commit locally + push branch + tag
# ---------------------------------------------------------------------------
echo "==> Step 5: Tag and push"
if ! git rev-parse "$TAG" >/dev/null 2>&1; then
    git tag "$TAG"
    echo "    Created local tag $TAG"
else
    echo "    Tag $TAG already exists locally."
fi

# After rebase, history is rewritten — force-with-lease is required for
# the branch push. The lease ensures we only overwrite if remote matches
# what we expect (safer than plain --force).
if ! git push "$ORIGIN_REMOTE" "$ORIGIN_BRANCH"; then
    echo "    Fast-forward push failed (history rewritten by rebase)."
    echo "    Retrying with --force-with-lease..."
    git push "$ORIGIN_REMOTE" "$ORIGIN_BRANCH" --force-with-lease
fi
echo "    Pushed $ORIGIN_BRANCH"

if ! git push "$ORIGIN_REMOTE" "$TAG" 2>/dev/null; then
    echo "    Tag $TAG already on remote (or push failed)."
    echo "    To overwrite: git push $ORIGIN_REMOTE $TAG --force"
else
    echo "    Pushed tag $TAG"
fi

echo ""
echo "==> All done!"
echo "    Release: https://github.com/$GITHUB_REPO/releases/tag/$TAG"
