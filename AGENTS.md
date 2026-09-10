# Harness Kit contributor instructions

This is the source repository for the portable harness bundle. The rules below
apply to work on this repository and to all feature, maintenance and release
branches. Read README.md for the affected verification commands before changing
the bundle.

## Mandatory Git-flow authorization

These rules apply to every project and branch, including this repository.
Project defaults, skills, past practice and release requests do not relax them.

- Never force-push `main`, `dev` or `develop`, including `--force-with-lease`,
  force refspecs and equivalent API/ref updates.
- Use one dedicated work branch per feature and deliver it through a PR/MR.
  The user must explicitly name its target branch. If missing, ask and do not
  create/retarget the PR/MR, merge, or push to a target; never infer the target
  from the current/default branch.
- Never bypass the PR/MR with a direct push, fast-forward, local merge or ref
  update to the target branch. Naming a PR target is not permission to merge;
  merging requires a separate explicit user instruction.
- Prefer one branch, one commit, counting commits introduced since the recorded
  branch base. If the branch already has more than two commits, or the next
  commit would exceed two, ask the user to choose keep/squash/split before
  committing, pushing or rewriting history. Do not automatically amend,
  squash, reset or rebase to satisfy this preference.
- Any history rewrite or force-push on other branches also requires explicit
  user authorization; `--force-with-lease` is not implicit permission.
- Create or push any tag only when the user authorizes that action and
  explicitly names its source branch. Verify the intended commit belongs to
  that branch. Never infer the source from HEAD, the default branch, the PR
  target or a request to "release". Do not move existing tags. Tag authorization
  does not authorize merging or pushing the source/target branch.

## Repository boundaries

- Keep canonical bundle sources and generated mirrors consistent. Follow
  `agent-bootstrap/MANIFEST.md`; run its required drift test after bundle edits.
- Development records are local-only except `docs/superpowers/specs/` and its
  policy README. Follow `docs/superpowers/README.md`; do not commit evidence,
  plans, caches or unrelated user files.
- Preserve existing project configuration and USER overlays during upgrades.
- These root instructions describe contributions to the kit itself. They do not
  install a generated downstream runtime in this repository.
