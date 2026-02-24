#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Config
# -----------------------------
PREFIX="v"
DEFAULT_BUMP="patch"
BUMP="${1:-$DEFAULT_BUMP}"

# -----------------------------
# Validate bump type early
# -----------------------------
case "$BUMP" in
  major|minor|patch) ;;
  *)
    echo "error: unknown bump type: '$BUMP'"
    echo "usage: $0 [major|minor|patch]"
    exit 1
    ;;
esac

# -----------------------------
# Guard: must be in a git repo
# -----------------------------
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "error: not a git repository"
  exit 1
fi

# -----------------------------
# Guard: working tree must be clean
# -----------------------------
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "error: working tree has uncommitted changes — commit or stash first"
  exit 1
fi

# -----------------------------
# Guard: must be on main/master
# -----------------------------
BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [[ "$BRANCH" != "main" && "$BRANCH" != "master" ]]; then
  echo "error: releases must be created from main/master (current: $BRANCH)"
  exit 1
fi

# -----------------------------
# Get last tag
# -----------------------------
LAST_TAG=$(git tag --list "${PREFIX}*" --sort=-v:refname | head -n 1)
if [[ -z "$LAST_TAG" ]]; then
  LAST_TAG="${PREFIX}0.0.0"
  echo "No previous tags found, starting from ${LAST_TAG}"
else
  echo "Last tag: $LAST_TAG"
fi

# -----------------------------
# Collect commits since last tag
# -----------------------------
if git rev-parse "$LAST_TAG" >/dev/null 2>&1; then
  COMMITS=$(git log "${LAST_TAG}..HEAD" --pretty=format:"- %s")
else
  COMMITS=$(git log --pretty=format:"- %s")
fi

if [[ -z "$COMMITS" ]]; then
  echo "error: no new commits since $LAST_TAG — nothing to release"
  exit 1
fi

# -----------------------------
# Parse and bump version
# -----------------------------
VERSION="${LAST_TAG#"${PREFIX}"}"
IFS='.' read -r MAJOR MINOR PATCH <<<"$VERSION"

case "$BUMP" in
  major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
  minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
  patch) PATCH=$((PATCH + 1)) ;;
esac

NEW_TAG="${PREFIX}${MAJOR}.${MINOR}.${PATCH}"

# -----------------------------
# Guard: tag must not already exist
# -----------------------------
if git rev-parse "$NEW_TAG" >/dev/null 2>&1; then
  echo "error: tag $NEW_TAG already exists"
  exit 1
fi

# -----------------------------
# Preview and confirm
# -----------------------------
echo ""
echo "  bump:     $BUMP"
echo "  previous: $LAST_TAG"
echo "  new tag:  $NEW_TAG"
echo ""
echo "Commits:"
echo "$COMMITS"
echo ""
read -r -p "Create and push tag $NEW_TAG? [y/N] " CONFIRM
if [[ "${CONFIRM,,}" != "y" ]]; then
  echo "Aborted."
  exit 0
fi

# -----------------------------
# Create annotated tag and push
# -----------------------------
git tag -a "$NEW_TAG" -m "${NEW_TAG}

Changes:
${COMMITS}
"

git push origin "$NEW_TAG"

echo ""
echo "✅ Released $NEW_TAG"
echo ""
echo "Build with:"
echo "  zig build -Dversion=\"\$(git describe --tags --always)\""
