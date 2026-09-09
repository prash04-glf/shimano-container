# Shimano GDAM 1 - AEM Application Codebase

This repository contains application components, templates, dialogs, clientlibs, and content packages for Shimano GDAM 1.

---

## 1. Modules Breakdown

* **`core/`**: Custom OSGi models, servlets, and backend logic.
* **`ui.apps/`**: AEM components, clientlibs, HTL templates, and dialog definitions.
* **`ui.apps.structure/`**: Repository structure definitions.
* **`ui.content/`**: Initial content package structure.
* **`ui.config/`**: Runmode-specific OSGi configurations.
* **`ui.frontend/`**: Webpack / Frontend asset compilation pipeline.
* **`all/`**: Container package combining bundle and content packages.
* **`it.tests/`**: Integration test suite.
* **`ui.tests/`**: Cypress-based end-to-end UI tests.

---

## 2. Local Development & Build

### Prerequisites
* Java JDK 11
* Maven 3.8+
* Node.js & NPM

### Build Commands
```bash
# Build and package all modules
mvn clean install

# Build and skip unit tests
mvn clean install -DskipTests

# Auto-install single package to local AEM Author instance (port 4502)
mvn clean install -PautoInstallSinglePackage
```

---

## 3. CI/CD Workflows & Multi-Repo Aggregation

This repository is connected to the aggregator container [`shimano-container`](https://github.com/prash04-glf/shimano-container).

```
+---------------------------+        Push / Merge to Whitelisted Branch
|  shimano-gdam-1           | -------------------------------------------+
+---------------------------+                                            |
              |                                                          v
              | .github/workflows/trigger-container.yml   +-----------------------------+
              | (evaluates vars.ALLOWED_BRANCHES)         | repository_dispatch         |
              +-----------------------------------------> | (event: subtree_sync)       |
                                                          +-----------------------------+
                                                                         |
                                                                         v
                                                          +-----------------------------+
                                                          |  shimano-container          |
                                                          |  .github/workflows/         |
                                                          |  update-subtree.yml         |
                                                          |  (git subtree pull --squash)|
                                                          +-----------------------------+
```

### GitHub Configuration
1. **Secret (`CONTAINER_DISPATCH_TOKEN`)**:
   - Location: **Settings > Secrets and variables > Actions > Secrets**
   - Value: Personal Access Token (PAT) with `repo` scope to dispatch events to `shimano-container`.
2. **Variable (`ALLOWED_BRANCHES`)**:
   - Location: **Settings > Secrets and variables > Actions > Variables**
   - Default: `main,develop,stage,stage-*,release/*,hotfix/*`
   - Purpose: Controls which branches are allowed to trigger subtree synchronization. Feature branches outside this list are skipped automatically, saving Action minutes.

### Active Workflows
* **`.github/workflows/pr-build.yml`**: Validates pull request builds with `mvn clean package -DskipTests` before merge.
* **`.github/workflows/trigger-container.yml`**: Dispatches subtree synchronization events to `shimano-container` upon push to allowed branches.
