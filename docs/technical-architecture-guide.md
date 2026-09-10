# Shimano Multi-Repository Delivery Architecture

> **Audience**: Development Teams, Tech Leads, DevOps & Security Engineers  
> **Repository**: `shimano-container` (Aggregator)  
> **Source Repositories**: `shimano-commons`, `shimano-gdam-1`, `shimano-bikes`

---

## 1. Architectural Blueprint & Delivery Lifecycle

```mermaid
flowchart TD
    subgraph S1["1. Local Engineering & PR Validation"]
        DEV["Developer Local AEM SDK"]
        PR_BUILD["pr-build.yml<br/>Fast Maven Validation<br/>(mvn clean package -DskipTests)"]
        DEV -->|"Create PR"| PR_BUILD
    end

    subgraph S2["2. Source Repositories"]
        COMMONS["shimano-commons<br/>(Common OSGi & Dispatcher)"]
        GDAM["shimano-gdam-1<br/>(GDAM Application)"]
        BIKES["shimano-bikes<br/>(Future Apps)"]
    end

    subgraph S3["3. PR Merge & Trigger"]
        MERGE["PR Merged into<br/>develop / stage / main"]
        TRIGGER["trigger-container.yml<br/>(repository_dispatch)"]
        MERGE --> TRIGGER
    end

    subgraph S4["4. Container Aggregator (shimano-container)"]
        SYNC_WF["update-subtree.yml<br/>(concurrency queue)"]
        SHIELD["update_subtree.sh<br/>6-Point Safety Shield"]
        subgraph SHIELD_STEPS["Safety Shield Execution"]
            G1["1. Whitelist Filter"]
            G2["2. Target Branch Exists"]
            G3["3. Source Remote Exists"]
            G4["4. Git Subtree Add/Pull (--squash)"]
            G5["5. Maven Reactor Gate (mvn validate)"]
            G6["6. Push Retry & Conflict Reconciliation"]
        end
        SYNC_WF --> SHIELD
        SHIELD --> SHIELD_STEPS
    end

    subgraph S5["5. Adobe Cloud Platform"]
        CM["Adobe Cloud Manager"]
        DEV_ENV["Dev Environment<br/>(Continuous)"]
        STAGE_ENV["Stage Environment<br/>(Testing)"]
        PROD_ENV["Prod Environment<br/>(Release Gates)"]
        CM --> DEV_ENV & STAGE_ENV & PROD_ENV
    end

    PR_BUILD -->|"PR Approved & Green"| S2
    S2 --> MERGE
    TRIGGER -->|"Subtree Sync Event"| SYNC_WF
    SHIELD_STEPS -->|"Push Clean Commit"| CM

    classDef active fill:#e8f4fd,stroke:#2b6cb0,stroke-width:2px;
    classDef future fill:#f7fafc,stroke:#a0aec0,stroke-width:1px,stroke-dasharray: 5 5;
    class DEV,PR_BUILD,COMMONS,GDAM,MERGE,TRIGGER,SYNC_WF,SHIELD,G1,G2,G3,G4,G5,G6,CM,DEV_ENV,STAGE_ENV,PROD_ENV active;
    class BIKES future;
```

---

## 2. Core Operational Pillars

### 1. Developer Autonomy
Developers work exclusively within their assigned source repository. They develop against their local AEM SDK, commit code, and open PRs without having to clone or build the entire platform reactor.

### 2. Fast PR Quality Feedback
Each source repository has a dedicated `.github/workflows/pr-build.yml` workflow:
- Command: `mvn -B clean package -DskipTests` (Fast build in ~1-2 min).
- Result: Fast feedback loops for developers on every pull request.
- Extensible: Ready to integrate SonarQube analysis and Veracode SAST scans.

### 3. Automated Subtree Synchronization
When a PR is merged into any whitelisted branch (`develop`, `stage`, `stage-*`, `release/*`, `main`):
1. `trigger-container.yml` in the source repository fires a `repository_dispatch` event (`subtree_sync`) with payload:
   ```json
   {
     "source_repo": "shimano-gdam-1",
     "source_branch": "develop",
     "commit_sha": "${{ github.sha }}",
     "actor": "${{ github.actor }}",
     "ref": "${{ github.ref }}"
   }
   ```
2. In `shimano-container`, the `.github/workflows/update-subtree.yml` workflow receives the event and executes `scripts/update_subtree.sh`.

---

## 3. The 6-Point Subtree Synchronization Safety Shield

`scripts/update_subtree.sh` enforces the following gates:

```
[Incoming Sync Event]
        │
        ▼
[Gate 1: Whitelist Filter] ─── NOT ALLOWED ───► Exit 0 (Skipped gracefully)
        │ ALLOWED
        ▼
[Gate 2: Container Branch Exists?] ─── NO ────► Exit 0 (Skip uninitialized branches)
        │ YES
        ▼
[Gate 3: Remote Source Branch Exists?] ── NO ─► Exit 1 (Fail fast, zero fallback)
        │ YES
        ▼
[Gate 4: Subtree Directory Check]
        ├── NOT FOUND ──► git subtree add --squash
        └── EXISTS ─────► git subtree pull --squash
        │
        ▼
[Gate 5: Maven Reactor Health Gate] ─── FAIL ─► Exit 1 (Abort push, protect container)
        │ PASS (mvn validate)
        ▼
[Gate 6: Safe Push & Push Retry]
        ├── UP TO DATE ─► Exit 0 (Idempotent)
        ├── SUCCESS ────► Pushed to remote
        └── 409 CONFLICT ──► Fetch, merge, re-validate, retry (up to 3x)
```

---

## 4. Concurrency & Push Retry Mechanism

When multiple pull requests are merged simultaneously across repositories (e.g. `shimano-commons` and `shimano-gdam-1` merged at the exact same moment):

```mermaid
sequenceDiagram
    autonumber
    actor DevA as Developer (GDAM)
    actor DevB as Developer (Commons)
    participant RepoG as shimano-gdam-1
    participant RepoC as shimano-commons
    participant Container as shimano-container (Actions)
    participant Maven as Maven Reactor Gate
    participant Remote as GitHub Remote (develop)

    par Simultaneous Merges
        DevA->>RepoG: Merge PR into develop
        RepoG->>Container: dispatch (shimano-gdam-1:develop)
    and
        DevB->>RepoC: Merge PR into develop
        RepoC->>Container: dispatch (shimano-commons:develop)
    end

    Note over Container: Job 1 starts (GDAM) | Job 2 queues (Commons)

    rect rgb(240, 248, 255)
        Note over Container: Processing Job 1 (GDAM)
        Container->>Container: git subtree pull --squash shimano-gdam-1
        Container->>Maven: mvn -B validate (5-10 seconds)
        Maven-->>Container: ✅ Reactor Valid
        Container->>Remote: git push origin develop
        Remote-->>Container: ✅ Success (Commit A)
    end

    rect rgb(255, 248, 240)
        Note over Container: Processing Job 2 (Commons)
        Container->>Container: git subtree pull --squash shimano-commons
        Container->>Remote: git push origin develop
        Remote-->>Container: ❌ 409 Rejected (Remote has Commit A)
        
        Note over Container: Push Retry Activates (Attempt 2 of 3)
        Container->>Remote: git fetch origin develop
        Container->>Container: git merge origin/develop -m "Merge concurrent changes"
        Container->>Maven: Re-run mvn validate
        Maven-->>Container: ✅ Reactor Valid
        Container->>Remote: git push origin develop
        Remote-->>Container: ✅ Success (Commit B)
    end
```

---

## 5. Security & Organization Token Architecture

```
                      GitHub Organization: prash04-glf
                                     │
       ┌─────────────────────────────┴─────────────────────────────┐
       ▼                                                           ▼
Organization Secret:                                        Organization Variable:
CONTAINER_DISPATCH_TOKEN                                    ALLOWED_BRANCHES
(Read/Write repo scope)                                     (main,develop,stage,stage-*,release/*,hotfix/*)
       │                                                           │
       ├─────────────────────────────┬─────────────────────────────┤
       ▼                             ▼                             ▼
shimano-commons              shimano-gdam-1                shimano-container
(Inherits Secret)            (Inherits Secret)             (Inherits Secret)
```

- **Zero Duplication**: The token is stored once in Organization Secrets and inherited by all repositories.
- **Principle of Least Privilege**: Source repository workflow runs only require read access to their own code plus permission to dispatch to `shimano-container`.

---

## 6. Subtree Directory & POM Reactor Structure

```text
shimano-container/
├── .cloudmanager/
│   └── java-version            <-- Java 21 specification
├── .github/
│   └── workflows/
│       └── update-subtree.yml  <-- Subtree sync engine
├── scripts/
│   └── update_subtree.sh       <-- Safety shield & push retry script
├── all/                        <-- Central packaging container
├── dispatcher/                 <-- Adobe Cloud Manager dispatcher config
├── shimano-commons/            <-- Subtree prefix: shimano-commons
│   ├── core/
│   └── ui.config/
├── shimano-gdam-1/             <-- Subtree prefix: shimano-gdam-1
│   ├── core/
│   ├── ui.apps/
│   ├── ui.config/
│   ├── ui.content/
│   └── ui.frontend/
├── shimano-bikes/              <-- Subtree prefix: shimano-bikes (Future)
└── pom.xml                     <-- Parent reactor aggregating all subtrees
```

---

## 7. Troubleshooting & FAQ

#### Q1: A push happened in `shimano-gdam-1`, but the container didn't update. Why?
1. Check GitHub Actions in `shimano-gdam-1` → `Trigger Shimano Container Subtree Sync`.
2. Did the branch match `ALLOWED_BRANCHES`? If it was `feature/xyz`, it is skipped by design.
3. Check `CONTAINER_DISPATCH_TOKEN` secret validity.

#### Q2: What happens if two developers merge PRs in GDAM and Commons at the same second?
1. The GitHub `concurrency` group queues the two runs sequentially.
2. If both sync jobs overlap, Step 6 in `update_subtree.sh` catches the push conflict, fetches the latest container state, merges cleanly, re-runs `mvn validate`, and retries the push automatically.
