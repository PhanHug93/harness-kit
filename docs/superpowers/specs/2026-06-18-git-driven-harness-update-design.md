# Git-Driven Harness Update Design

## Goal

Target projects should be able to proactively discover that a newer harness
version has been published to Git, update the canonical harness home, and then
preview or apply project-local generated changes through the existing
non-destructive upgrade flow.

## Current State

The kit already records `installed_version` in
`docs/agent-configs/agent-bootstrap.lock.json` and compares it with the local
bundle's `bundle_version` through `--status --json`. The project upgrade path
also has `--diff`, `--upgrade-plan`, generated candidates, and
`--apply-candidates`.

The missing DevOps surface is upstream discovery. A target project can compare
itself with the local `$AGENT_BOOTSTRAP_HOME`, but it cannot ask whether Git has
a newer released tag or refresh that canonical home without a manual clone/pull
procedure.

## Requirements

- Add a bundle updater entrypoint that works from `$AGENT_BOOTSTRAP_HOME`.
- Check remote Git tags and report whether a newer `vYYYY.MM.DD.N` release is
  available.
- Self-update the canonical home by cloning the selected tag into a temporary
  directory, verifying `agent-bootstrap/VERSION`, and running the bundled home
  installer into the existing home.
- Write source metadata into the canonical home so future checks know the
  upstream repository, installed ref, installed commit, and installed version.
- Let a project invoke a single command to show upstream update status and then
  print the existing target upgrade plan.
- Keep project application non-destructive: generation may create visible
  candidates, but candidate promotion remains a separate reviewed step.
- Keep tests network-free by using local Git repositories and tags.

## Architecture

`agent-bootstrap/agent-bootstrap-update.sh` is the control-plane entrypoint. It
does not replace `bootstrap-multi-agent-project.sh`; it orchestrates upstream
version discovery and then delegates target work to the existing generator.

`agent-bootstrap/install-agent-bootstrap-home.sh` remains the writer for the
canonical home. It gains `SOURCE.json` metadata writing and copies the updater
into home. Shell setup gains two functions:

- `agent-update`: operate on `$AGENT_BOOTSTRAP_HOME`.
- `agent-upgrade`: operate on the current project through the updater.

## Safety Model

The updater never mutates a project while checking for upstream versions.
`--self-update` mutates only the canonical home. `--target --plan` only prints
status and the generator's upgrade plan. `--target --apply` delegates to normal
generation, which preserves existing files by producing visible
`*.generated.<timestamp>` candidates unless the operator separately chooses a
force path.

The updater does not trust a tag name by itself. After cloning the tag, it
checks that `agent-bootstrap/VERSION` matches the selected release version and
that the home installer exists before replacing canonical home files.

## Testing

The integration test builds a local fixture Git repository with an old and a
new release tag, installs the canonical home from the old tag, checks update
JSON against the local repo, self-updates to the new tag, and confirms a target
created from the old home can print a new-version upgrade plan.
