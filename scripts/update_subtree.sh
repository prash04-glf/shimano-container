#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Shimano Container - Git Subtree Synchronization Script
# Synchronizes source repositories (shimano-gdam-1, shimano-commons) into host
# -----------------------------------------------------------------------------

SOURCE_REPO="${SOURCE_REPO:-}"
SOURCE_BRANCH="${SOURCE_BRANCH:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
ORG_NAME="${ORG_NAME:-prash04-glf}"

echo "================================================================="
echo " Starting Subtree Synchronization"
echo " Time          : $(date -u)"
echo " Source Repo   : ${SOURCE_REPO}"
echo " Source Branch : ${SOURCE_BRANCH}"
echo " Target Branch : ${SOURCE_BRANCH}"
echo " Host Org      : ${ORG_NAME}"
echo "================================================================="

# 1. Validate required inputs
if [ -z "$SOURCE_REPO" ]; then
  echo "❌ ERROR: SOURCE_REPO is not set."
  exit 1
fi

if [ -z "$SOURCE_BRANCH" ]; then
  echo "❌ ERROR: SOURCE_BRANCH is not set."
  exit 1
fi

# 2. Enforce strict branch whitelist
case "$SOURCE_BRANCH" in
  main|develop|stage|release/*)
    echo "✓ Valid branch: ${SOURCE_BRANCH}"
    ;;\
  *)
    echo "❌ ERROR: Branch '${SOURCE_BRANCH}' is not whitelisted for subtree synchronization."
    exit 1
    ;;
esac

# 3. Configure Git author identity and settings
git config --global user.name "github-actions[bot]"
git config --global user.email "github-actions[bot]@users.noreply.github.com"
git config --global pull.rebase false

# 4. Construct Authenticated Remote URL
if [ -n "$GITHUB_TOKEN" ]; then
  SOURCE_REMOTE="https://x-access-token:${GITHUB_TOKEN}@github.com/${ORG_NAME}/${SOURCE_REPO}.git"
else
  SOURCE_REMOTE="https://github.com/${ORG_NAME}/${SOURCE_REPO}.git"
fi

# 5. Check if source branch exists on remote
echo ""
echo "Checking remote branch '${SOURCE_BRANCH}' in ${SOURCE_REPO}..."
if ! git ls-remote --exit-code --heads "$SOURCE_REMOTE" "$SOURCE_BRANCH" > /dev/null 2>&1; then
  echo "⚠️ Subtree branch '${SOURCE_BRANCH}' does not exist on remote ${SOURCE_REPO}. Falling back to 'main'..."
  SOURCE_BRANCH="main"
  if ! git ls-remote --exit-code --heads "$SOURCE_REMOTE" "$SOURCE_BRANCH" > /dev/null 2>&1; then
    echo "❌ ERROR: Neither original branch nor 'main' exists in ${SOURCE_REPO}."
    exit 1
  fi
fi
echo "✓ Using verified remote branch: ${SOURCE_BRANCH}"

SUBTREE_PREFIX="${SOURCE_REPO}"

# Ensure working tree is clean before any git subtree operation
git reset --hard HEAD
git clean -fd

# 6. Add or Pull Subtree with --squash
echo ""
if [ ! -d "$SUBTREE_PREFIX" ]; then
  echo "📦 Subtree directory '${SUBTREE_PREFIX}' does not exist. Adding subtree..."
  git subtree add --prefix="$SUBTREE_PREFIX" "$SOURCE_REMOTE" "$SOURCE_BRANCH" --squash -m "Add ${SOURCE_REPO} subtree from ${SOURCE_BRANCH}"
  echo "✓ Subtree '${SUBTREE_PREFIX}' added successfully."
else
  echo "📦 Subtree directory '${SUBTREE_PREFIX}' exists. Pulling latest changes..."
  git subtree pull --prefix="$SUBTREE_PREFIX" "$SOURCE_REMOTE" "$SOURCE_BRANCH" --squash -m "Update ${SOURCE_REPO} subtree from ${SOURCE_BRANCH}"
  echo "✓ Subtree '${SUBTREE_PREFIX}' updated successfully."
fi

# 7. Check if there are new commits to push
echo ""
echo "Checking commit state against remote..."
git fetch origin "$SOURCE_BRANCH" || true
LOCAL_SHA=$(git rev-parse HEAD)
REMOTE_SHA=$(git rev-parse "origin/${SOURCE_BRANCH}" 2>/dev/null || echo "")

echo "Local Commit  : ${LOCAL_SHA}"
echo "Remote Commit : ${REMOTE_SHA}"

if [ "$LOCAL_SHA" = "$REMOTE_SHA" ]; then
  echo "ℹ️ Container is already up-to-date with ${SOURCE_REPO}. No changes to push."
  exit 0
fi

# 8. Push changes safely to container repository
echo ""
echo "Pushing changes to origin/${SOURCE_BRANCH}..."
if git push origin "HEAD:${SOURCE_BRANCH}"; then
  echo "✅ Changes pushed successfully."
else
  echo "⚠️ Direct push rejected. Fetching origin changes and merging..."
  git pull origin "${SOURCE_BRANCH}" --no-edit
  git push origin "HEAD:${SOURCE_BRANCH}"
  echo "✅ Push succeeded on retry."
fi

echo ""
echo "================================================================="
echo " Subtree synchronization completed successfully for ${SOURCE_REPO}"
echo "================================================================="
