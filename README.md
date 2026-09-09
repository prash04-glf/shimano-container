# Shimano Container - AEM Multi-Repository Aggregator

This repository aggregates multiple source repositories (`shimano-gdam-1`, `shimano-commons`, etc.) into a unified codebase using **Git Subtree** and automates synchronization via **GitHub Actions**. It serves as the single deployment repository connected to **Adobe Experience Manager (AEM) Cloud Manager**.

---

## 1. Architecture Diagram

```
+------------------------------------+        +------------------------------------+
|       shimano-gdam-1               |        |       shimano-commons              |
|  (Application Code)                |        |  (Shared Libraries / Core)         |
|  Branches: develop | main | stage  |        |  Branches: develop | main | stage  |
+------------------------------------+        +------------------------------------+
                   │                                             │
                   │ Push / Merge                                │ Push / Merge
                   ▼                                             ▼
  .github/workflows/trigger-container.yml       .github/workflows/trigger-container.yml
                   │                                             │
                   └──────────────────────┬──────────────────────┘
                                          │
                                          │ repository_dispatch (event: subtree_sync)
                                          │ payload: { source_repo, source_branch }
                                          ▼
                      +----------------------------------------+
                      |           shimano-container            |
                      |   .github/workflows/update-subtree.yml |
                      |   Concurrency group per target branch  |
                      +----------------------------------------+
                                          │
                                          │ 1. Match against ALLOWED_BRANCHES
                                          │ 2. Check target branch exists in container (Governance)
                                          │ 3. Check branch exists in source repo (Zero fallback)
                                          │ 4. Pull subtree locally (--squash)
                                          │ 5. Quality Gate: mvn validate (5-10s)
                                          │ 6. Push to remote with retry & re-validation loop
                                          ▼
                      +────────────────────────────────────────+
                      |   Adobe Cloud Manager Webhook Deploy   |
                      |   Non-Prod -> develop                  |
                      |   Stage    -> stage                    |
                      |   Prod     -> main                     |
                      +────────────────────────────────────────+
```

---

## 2. Directory Structure

```
shimano-container/
├── .github/
│   └── workflows/
│       └── update-subtree.yml      # Subtree sync workflow & concurrency queue
├── scripts/
│   └── update_subtree.sh           # Sync script, quality gate & push retry loop
├── pom.xml                         # Aggregator root POM
├── README.md                       # Comprehensive architecture & operations guide
├── shimano-commons/                # Git subtree for shimano-commons
└── shimano-gdam-1/                 # Git subtree for shimano-gdam-1
```

---

## 3. Branch Governance & Onboarding

### Strict Branch Governance Model
To ensure complete control over deployment targets and prevent rogue or unintended branches:
- **No Automatic Branch Creation in Container**: If a new branch is pushed in a source repository (e.g. `release/v2.0` or `stage-2`), the container workflow **will not automatically create it**.
- **Controlled Skipping**: The workflow logs a clear notice:
  `⚠️ NOTICE: Target branch 'release/v2.0' does not exist in container repository. Subtree synchronization skipped.`
- **Zero Fallback to `main`**: The pipeline **never falls back to `main`**. If a source branch does not exist on the remote source repo, it fails fast (`exit 1`) to eliminate any risk of code pollution.

### How to Onboard a New Branch to the Container
When a Release Manager or Team Lead wants to sync a new release or stage branch:
1. Create and push the branch in `shimano-container` (e.g. `git checkout develop && git checkout -b release/v2.0 && git push origin release/v2.0`).
2. Any subsequent merges to `release/v2.0` in `shimano-gdam-1` or `shimano-commons` will now automatically sync into `shimano-container:release/v2.0`.

---

## 4. Dynamic Whitelist Configuration (`ALLOWED_BRANCHES`)

The list of branches eligible for subtree synchronization is configurable via GitHub Variables without touching code:

- **Location**: **Repository / Organization Settings $\rightarrow$ Secrets and variables $\rightarrow$ Actions $\rightarrow$ Variables**
- **Variable Name**: `ALLOWED_BRANCHES`
- **Default Value**: `main,develop,stage,stage-*,release/*,hotfix/*`

Any branch not matching this comma-separated pattern list is cleanly skipped. Branch patterns support standard wildcards (`*` matches single segment or prefix, e.g. `stage-*`, `release/*`, `hotfix/*`). Additional patterns can be configured anytime via repository variables.

---

## 5. Build Strategy: Fast Quality Gate vs Cloud Manager Full Build

- **PR Validation / Fast Quality Gate (`mvn validate`)**:
  - Validates POM syntax, dependency convergence, and aggregator reactor integrity in 5–10 seconds.
  - Keeps PR and subtree synchronization fast and lightweight without duplicating full compilation overhead.
- **Adobe Cloud Manager Pipeline (Full Build)**:
  - Executes complete AEM maven packaging, frontend build (Node/NPM), code quality scanning, unit tests, integration tests, and environment deployments.

---

## 6. How to Block PR Merges on Failed Build (GitHub Branch Protection)

By default, GitHub Actions runs the PR workflow (`Validate PR Build`), but does not prevent merging unless **Branch Protection Rules** (or **Rulesets**) are explicitly turned on in GitHub repository settings.

### Step-by-Step Guide to Enforce Merge Blocking:
1. Go to your repository on GitHub (`shimano-commons`, `shimano-gdam-1`, or `shimano-container`).
2. Navigate to **Settings** $\rightarrow$ **Branches** (under *Code and automation*).
3. Click **Add branch protection rule** (or edit existing rule for `develop`, `main`, etc.).
4. In **Branch name pattern**, enter `develop` (or `main`, `stage`).
5. Check ✅ **Require a pull request before merging**.
6. Check ✅ **Require status checks to pass before merging**.
7. In the search box, search for and select:
   - **`Validate PR Build`** (this matches the job name in `.github/workflows/pr-build.yml`).
8. *(Optional but recommended)* Check ✅ **Require branches to be up to date before merging**.
9. Click **Create** / **Save changes**.

> **Result**: The green "Merge Pull Request" button will remain blocked/disabled until the `Validate PR Build` check runs and finishes with a green checkmark (`SUCCESS`).

---

## 7. Concurrency & Push Retry Safety

When multiple PRs are merged simultaneously across repositories:
1. **GitHub Concurrency Queue**: `group: subtree-sync-${{ env.SOURCE_BRANCH }}` with `cancel-in-progress: false` queues incoming sync events sequentially.
2. **Push Retry & Re-Validation Loop**: If a rare race condition occurs during push:
   - The script fetches the remote commit.
   - Merges the remote state non-interactively.
   - **Re-runs `mvn -B validate`** to guarantee reactor integrity after the merge.
   - Retries the push (up to 3 attempts).

---

## 8. Security & Credentials Setup

| Variable / Secret | Type | Location | Purpose |
| :--- | :--- | :--- | :--- |
| `CONTAINER_DISPATCH_TOKEN` | Secret | Org / Repo Secrets | GitHub Personal Access Token (PAT with `repo` scope) used to trigger dispatch events and authenticate subtree operations. |
| `ALLOWED_BRANCHES` | Variable | Org / Repo Variables | Comma-separated list of whitelisted branch glob patterns. |

---

## 9. How to Add a New Subtree Repository Later

To add a 3rd repository (e.g., `shimano-dealer`):
1. Add `.github/workflows/trigger-container.yml` in `shimano-dealer` with secret `CONTAINER_DISPATCH_TOKEN`.
2. Add `<module>shimano-dealer</module>` in root `pom.xml`.
3. Add initial subtree on `develop` and `main`:
   ```bash
   git subtree add --prefix=shimano-dealer https://github.com/prash04-glf/shimano-dealer.git develop --squash -m "Add shimano-dealer subtree"
   ```
4. Commit and push. All future updates will be fully automated!
