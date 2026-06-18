# Git-Driven Harness Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Add a Git-backed updater so target projects can proactively discover new harness releases, refresh `$AGENT_BOOTSTRAP_HOME`, and run the existing safe project upgrade flow.

**Architecture:** Add `agent-bootstrap/agent-bootstrap-update.sh` as the update control plane. Extend `install-agent-bootstrap-home.sh` to copy the updater, write `SOURCE.json`, and install `agent-update`/`agent-upgrade` shell functions. Keep project mutation delegated to `bootstrap-multi-agent-project.sh`.

**Tech Stack:** Bash, Git, Python 3 for JSON/version sorting, existing shell integration tests.

---

### Task 1: Test Git Update Lifecycle

**Files:**
- Modify: `scripts/test-bootstrap-multi-agent-project.sh`

- [x] **Step 1: Write the failing test**

Add an integration helper that builds a local fixture Git repo with two tagged
versions of the bundle and validates check, self-update, and target plan
behavior.

- [x] **Step 2: Run the test to verify it fails**

Run: `bash scripts/test-bootstrap-multi-agent-project.sh`

Expected: failure because `agent-bootstrap/agent-bootstrap-update.sh` is missing
from the bundle.

### Task 2: Add Updater Entrypoint

**Files:**
- Create: `agent-bootstrap/agent-bootstrap-update.sh`

- [x] **Step 1: Implement update status**

Create a Bash entrypoint supporting `--home`, `--repo`, `--check`, and `--json`.
It reads local `VERSION`, reads `SOURCE.json` when present, lists remote tags
with `git ls-remote --tags --refs`, and chooses the latest semantic numeric
`vYYYY.MM.DD.N` tag using Python.

- [x] **Step 2: Implement self-update**

Support `--self-update`. Clone the selected tag into a temp directory, verify
`agent-bootstrap/VERSION`, then run that tag's
`agent-bootstrap/install-agent-bootstrap-home.sh` into the current home.

- [x] **Step 3: Implement project plan/apply delegation**

Support `--target DIR --plan` and `--target DIR --apply`. `--plan` prints
upstream status then delegates to `bootstrap-multi-agent-project.sh
--upgrade-plan`. `--apply` delegates to normal non-destructive generation.

### Task 3: Wire Installer, Manifest, Docs, and Shell Functions

**Files:**
- Modify: `agent-bootstrap/install-agent-bootstrap-home.sh`
- Modify: `agent-bootstrap/MANIFEST.md`
- Modify: `agent-bootstrap/README.md`
- Modify: `README.md`
- Modify: `docs/agent-configs/bootstrap-multi-agent-project/README.md`
- Modify: `.github/workflows/test.yml`
- Modify: `scripts/test-bootstrap-multi-agent-project.sh`

- [x] **Step 1: Copy updater into canonical home**

Add the updater to the installer copy list, manifest source roles, canonical
export test inventory, and shellcheck inputs.

- [x] **Step 2: Write source metadata**

Make the installer write `SOURCE.json` with schema, repo URL, installed ref,
installed commit, installed version, and timestamp. Prefer the source repo's
Git metadata; preserve an explicit existing repo URL if running from a copied
bundle without Git metadata.

- [x] **Step 3: Add shell functions**

Add `agent-update` and `agent-upgrade` to the managed shell block and tests.

- [x] **Step 4: Document operator workflow**

Document `agent-update --check`, `agent-update --self-update`, and
`agent-upgrade --plan`.

### Task 4: Verify

**Files:**
- No new files.

- [x] **Step 1: Run syntax checks**

Run: `bash -n agent-bootstrap/agent-bootstrap-update.sh`

Expected: exit 0.

- [x] **Step 2: Run integration gate**

Run: `bash scripts/test-bootstrap-multi-agent-project.sh`

Expected: exit 0 and `bootstrap-test: ok`.

- [x] **Step 3: Run generated target verifier**

Run:

```bash
tmp="$(mktemp -d)"
bash scripts/bootstrap-multi-agent-project.sh --target "$tmp" --workflow full
(cd "$tmp" && scripts/verify-ai-deps.sh && scripts/verify-ai-deps.sh --json | python3 -m json.tool >/dev/null)
rm -rf "$tmp"
```

Expected: exit 0.
