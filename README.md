# Shimano Container - AEM Multi-Repository Aggregator

This repository aggregates multiple source repositories (`shimano-gdam-1`, `shimano-commons`, etc.) into a unified codebase using **Git Subtree** and automates synchronization via **GitHub Actions**. It serves as the single deployment repository connected to **Adobe Experience Manager (AEM) Cloud Manager**.

---

## 1. Architecture Diagram

```
+------------------------------------+        +------------------------------------+
|       shimano-gdam-1               |        |       shimano-commons              |
|  (Application Code)                |        |  (Shared Libraries / Core)         |
|  Branches: develop | main          |        |  Branches: develop | main          |
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
                                          │ 1. Checkout matching container branch
                                          │ 2. Pull subtree locally (--squash)
                                          │ 3. Quality Gate: mvn validate (5-10s)
                                          │ 4. Push to remote with retry loop
                                          ▼
                      +────────────────────────────────────────+
                      |   Adobe Cloud Manager Webhook Deploy   |
                      |   Non-Prod -> develop                  |
                      |   Production -> main                   |
                      +────────────────────────────────────────+
```

---

## 2. Directory Structure

```
shimano-container/
├── .github/
│   └── workflows/
│       └── update-subtree.yml      # Synchronization workflow & concurrency queue
├── scripts/
│   └── update_subtree.sh           # Reusable subtree sync script & quality gate
├── pom.xml                         # Aggregator root POM
├── README.md                       # Architecture & setup guide
├── shimano-commons/                # Git subtree for shimano-commons
└── shimano-gdam-1/                 # Git subtree for shimano-gdam-1
```

---

## 3. Branch Mapping & Promotion Rules

| Source Branch | Container Branch | Target Subtree Directory | Cloud Manager Target |
| :--- | :--- | :--- | :--- |
| `develop` | `develop` | `shimano-gdam-1/` or `shimano-commons/` | Non-Production Pipeline |
| `main` | `main` | `shimano-gdam-1/` or `shimano-commons/` | Production Pipeline |
| `stage` | `stage` | `shimano-gdam-1/` or `shimano-commons/` | Stage Pipeline |
| `release/*` | `release/*` | `shimano-gdam-1/` or `shimano-commons/` | Release Pipeline |

### Golden Rules for Development & Releases
1. **Source Code & Components**:
   - Write code, components, templates, and clientlibs **only in the source repositories** (`shimano-gdam-1`, `shimano-commons`).
   - Merge PRs into `develop` in source repos $\rightarrow$ container `develop` updates automatically.
   - Merge Release PRs into `main` in source repos $\rightarrow$ container `main` updates automatically.
2. **Container Infrastructure**:
   - Workflows, sync scripts, and root `pom.xml` are edited directly in `shimano-container`.
3. **No Internal Branch Merges**:
   - Never merge `develop` $\leftrightarrow$ `main` inside the container repository. Each container branch mirrors the corresponding source branch.

---

## 4. Production Quality Gate (`mvn validate`)

Before any subtree update is pushed to GitHub, the sync script executes a lightweight **Maven Reactor Validation**:
```bash
mvn -B validate
```
- **Execution Time**: ~5 to 10 seconds.
- **What it checks**: Validates all aggregator POMs, child module paths, XML syntax, and prevents duplicate artifact IDs or missing module directories (e.g. missing dispatcher folders).
- **Quality Gate Protection**: If validation fails, the script **aborts immediately without pushing**, preventing broken commits from reaching Adobe Cloud Manager or other developers.

---

## 5. Concurrency & Race Condition Safety

When multiple PRs are merged simultaneously across repositories:
1. **GitHub Concurrency Queue**: `group: subtree-sync-${{ branch }}` with `cancel-in-progress: false` queues incoming events sequentially.
2. **Push Retry Loop**: If a race condition occurs, `scripts/update_subtree.sh` retries pushing up to 3 times, merging remote changes non-interactively before retrying.

---

## 6. How to Add a New Subtree Repository Later

To add a 3rd repository (e.g., `shimano-dealer`):
1. Add `.github/workflows/trigger-container.yml` in `shimano-dealer` with secret `CONTAINER_DISPATCH_TOKEN`.
2. Add `<module>shimano-dealer</module>` in root `pom.xml`.
3. Add initial subtree on `develop` and `main`:
   ```bash
   git subtree add --prefix=shimano-dealer https://github.com/prash04-glf/shimano-dealer.git develop --squash -m "Add shimano-dealer subtree"
   ```
4. Commit and push. The automated pipeline will handle all future updates!
