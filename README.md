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
                                          │ 2. Run scripts/update_subtree.sh
                                          ▼
                      +────────────────────────────────────────+
                      │ git subtree pull --squash              │
                      │ -> shimano-container/shimano-gdam-1/   │
                      │ -> shimano-container/shimano-commons/  │
                      +────────────────────────────────────────+
                                          │
                                          │ 3. Run aggregated Maven validation
                                          │ 4. Commit and push updated branch
                                          ▼
                      +────────────────────────────────────────+
                      |   Adobe Cloud Manager Webhook Deploy   |
                      +────────────────────────────────────────+
```

---

## 2. Directory Structure

```
shimano-container/
├── .github/
│   └── workflows/
│       └── update-subtree.yml      # Synchronization workflow
├── scripts/
│   └── update_subtree.sh           # Reusable subtree sync script
├── pom.xml                         # Aggregator root POM
├── README.md                       # Architecture & setup guide
├── shimano-commons/                # Git subtree for shimano-commons
└── shimano-gdam-1/                 # Git subtree for shimano-gdam-1
```

---

## 3. Branch Mapping Strategy

| Source Branch | Container Branch | Target Subtree Directory |
| :--- | :--- | :--- |
| `develop` | `develop` | `shimano-gdam-1/` or `shimano-commons/` |
| `main` | `main` | `shimano-gdam-1/` or `shimano-commons/` |
| `stage` | `stage` | `shimano-gdam-1/` or `shimano-commons/` |
| `release/*` | `release/*` | `shimano-gdam-1/` or `shimano-commons/` |

---

## 4. Git Subtree Strategy (`--squash`)

We use `git subtree pull --squash` because:
- **Clean Git History**: Compresses dozens of feature commits from individual projects into a single clean subtree update commit in the container.
- **Zero Submodule Overhead**: Developers and CI systems do not need `git submodule init / update`.
- **Cloud Manager Compatibility**: Adobe Cloud Manager builds from a standard Git repository without external submodule dependencies.

---

## 5. Setup & Authentication

1. **GitHub Secret**: Add `CONTAINER_DISPATCH_TOKEN` in repository secrets (**Settings > Secrets and variables > Actions**).
2. **Adobe Cloud Manager Webhook**: Under **Settings > Webhooks**, configure the webhook URL and secret from Adobe Cloud Manager.

---

## 6. How to Add a New Subtree Repository Later

To add a 3rd repository (e.g. `shimano-dealer`):
1. Add `.github/workflows/trigger-container.yml` in `shimano-dealer` with secret `CONTAINER_DISPATCH_TOKEN`.
2. Add `<module>shimano-dealer</module>` in `pom.xml`.
3. Add initial subtree:
   ```bash
   git subtree add --prefix=shimano-dealer https://github.com/prash04-glf/shimano-dealer.git develop --squash -m "Add shimano-dealer subtree"
   ```
4. Commit and push. The automated pipeline will handle all future updates!
