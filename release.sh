#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Config
# -----------------------------
PREFIX="v"           # tag prefix
DEFAULT_BUMP="patch" # patch | minor | major

BUMP="${1:-$DEFAULT_BUMP}"

# -----------------------------
# Get last tag
# -----------------------------
LAST_TAG=$(git tag --list "${PREFIX}*" --sort=-v:refname | head -n 1 || true)

if [[ -z "$LAST_TAG" ]]; then
  LAST_TAG="${PREFIX}0.0.0"
fi

echo "Last tag: $LAST_TAG"

VERSION="${LAST_TAG#${PREFIX}}"

IFS='.' read -r MAJOR MINOR PATCH <<<"$VERSION"

# -----------------------------
# Bump version
# -----------------------------
case "$BUMP" in
  major)
    MAJOR=$((MAJOR + 1))
    MINOR=0
    PATCH=0
    ;;
  minor)
    MINOR=$((MINOR + 1))
    PATCH=0
    ;;
  patch)
    PATCH=$((PATCH + 1))
    ;;
  *)
    echo "Unknown bump type: $BUMP"
    echo "Usage: ./release.sh [major|minor|patch]"
    exit 1
    ;;
esac

NEW_TAG="${PREFIX}${MAJOR}.${MINOR}.${PATCH}"
echo "New tag: $NEW_TAG"

# -----------------------------
# Collect commit messages
# -----------------------------
if git rev-parse "$LAST_TAG" >/dev/null 2>&1; then
  COMMITS=$(git log "${LAST_TAG}..HEAD" --pretty=format:"- %s")
else
  COMMITS=$(git log --pretty=format:"- %s")
fi

if [[ -z "$COMMITS" ]]; then
  echo "No new commits to release"
  exit 1
fi

# -----------------------------
# Create annotated tag
# -----------------------------
git tag -a "$NEW_TAG" -m "$NEW_TAG

Changes:
$COMMITS
"

# -----------------------------
# Push tag
# -----------------------------
git push origin "$NEW_TAG"

echo "✅ Release $NEW_TAG created and pushed"
