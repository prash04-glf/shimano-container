#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Shimano Container - Git Subtree Synchronization Script
# Synchronizes source repositories (shimano-gdam-1, shimano-commons) into host
# Features:
#   - Controlled branch governance (explicit container branch required)
#   - Zero silent fallback (fails fast if source branch is invalid)
#   - Dynamic branch whitelist from ALLOWED_BRANCHES variable
#   - Maven reactor quality gate (mvn validate)
#   - Concurrency & retry loop with fetch, merge, and re-validation
# -----------------------------------------------------------------------------

SOURCE_REPO="${SOURCE_REPO:-}"
SOURCE_BRANCH="${SOURCE_BRANCH:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
ORG_NAME="${ORG_NAME:-prash04-glf}"
ALLOWED_BRANCHES="${ALLOWED_BRANCHES:-main,develop,stage,stage-*,release/*,hotfix/*}"

echo "================================================================="
echo " Starting Subtree Synchronization"
echo " Time             : $(date -u)"
echo " Source Repo      : ${SOURCE_REPO}"
echo " Source Branch    : ${SOURCE_BRANCH}"
echo " Target Branch    : ${SOURCE_BRANCH}"
echo " Host Org         : ${ORG_NAME}"
echo " Allowed Branches : ${ALLOWED_BRANCHES}"
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

# 2. Dynamic branch whitelist check against ALLOWED_BRANCHES
IS_ALLOWED=false
IFS=',' read -ra BRANCH_PATTERNS <<< "$ALLOWED_BRANCHES"
for pattern in "${BRANCH_PATTERNS[@]}"; do
  pattern=$(echo "$pattern" | xargs)
  # shellcheck disable=SC2053
  if [[ "$SOURCE_BRANCH" == $pattern ]]; then
    IS_ALLOWED=true
    break
  fi
done

if [ "$IS_ALLOWED" != true ]; then
  echo "⚠️ NOTICE: Branch '${SOURCE_BRANCH}' does not match any pattern in ALLOWED_BRANCHES ('${ALLOWED_BRANCHES}')."
  echo "   Subtree synchronization skipped."
  exit 0
fi
echo "✓ Branch '${SOURCE_BRANCH}' matches allowed whitelist."

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

# 5. Check if target branch exists in CONTAINER repository
echo ""
echo "Checking if target branch '${SOURCE_BRANCH}' exists in container repository..."
if ! git ls-remote --exit-code --heads origin "$SOURCE_BRANCH" > /dev/null 2>&1; then
  echo "================================================================="
  echo "⚠️ NOTICE: Target branch '${SOURCE_BRANCH}' does not exist in container repository."
  echo "   Subtree synchronization skipped."
  echo "   To enable sync for this branch, a Release Manager or Developer"
  echo "   must first create the branch '${SOURCE_BRANCH}' in shimano-container."
  echo "================================================================="
  exit 0
fi
echo "✓ Target branch '${SOURCE_BRANCH}' verified in container repository."

# 6. Check if source branch exists on source remote (Zero fallback to main!)
echo ""
echo "Checking remote branch '${SOURCE_BRANCH}' in source repo ${SOURCE_REPO}..."
if ! git ls-remote --exit-code --heads "$SOURCE_REMOTE" "$SOURCE_BRANCH" > /dev/null 2>&1; then
  echo "================================================================="
  echo "❌ ERROR: Branch '${SOURCE_BRANCH}' does not exist in source repository '${SOURCE_REPO}'."
  echo "   Subtree synchronization aborted (no fallback to main)."
  echo "================================================================="
  exit 1
fi
echo "✓ Remote branch '${SOURCE_BRANCH}' verified in ${SOURCE_REPO}."

# 7. Checkout and clean target branch in container workspace
echo ""
echo "Checking out container branch '${SOURCE_BRANCH}'..."
git fetch origin "$SOURCE_BRANCH"
git checkout "$SOURCE_BRANCH"
git reset --hard "origin/${SOURCE_BRANCH}"
git clean -fd

SUBTREE_PREFIX="${SOURCE_REPO}"

# 8. Add or Pull Subtree with --squash locally
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

# 9. Maven Reactor Quality Gate (Verify POMs & modules BEFORE pushing)
echo ""
echo "================================================================="
echo " Running Maven Reactor Quality Gate (mvn validate)"
echo "================================================================="
if command -v mvn >/dev/null 2>&1; then
  if mvn -B validate; then
    echo "✅ Maven reactor validation passed successfully."
  else
    echo "❌ ERROR: Maven reactor validation failed!"
    echo "   Aborting push to prevent broken commits on ${SOURCE_BRANCH}."
    exit 1
  fi
else
  echo "⚠️ Maven not detected in PATH; skipping local validation."
fi

# 10. Check if there are new commits to push
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

# 11. Push changes safely to container repository with retry & re-validation loop
echo ""
echo "Pushing changes to origin/${SOURCE_BRANCH}..."
MAX_RETRIES=3
PUSHED=false

for ((i=1; i<=MAX_RETRIES; i++)); do
  if git push origin "HEAD:${SOURCE_BRANCH}"; then
    echo "✅ Changes pushed successfully on attempt $i."
    PUSHED=true
    break
  else
    if [ "$i" -lt "$MAX_RETRIES" ]; then
      echo "⚠️ Push rejected (attempt $i). Race condition detected with another commit."
      echo "   Fetching origin/${SOURCE_BRANCH}, merging, and re-validating quality gate..."
      git fetch origin "${SOURCE_BRANCH}"
      git pull origin "${SOURCE_BRANCH}" --no-edit || true
      if command -v mvn >/dev/null 2>&1; then
        mvn -B validate || { echo "❌ Quality gate failed after merge retry!"; exit 1; }
      fi
    fi
  fi
done

if [ "$PUSHED" != true ]; then
  echo "❌ Push failed after $MAX_RETRIES attempts."
  exit 1
fi

echo ""
echo "================================================================="
echo " Subtree synchronization completed successfully for ${SOURCE_REPO}"
echo " Target Branch : ${SOURCE_BRANCH}"
echo " Head Commit   : $(git rev-parse --short HEAD)"
echo "================================================================="
