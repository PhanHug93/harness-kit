# Superpowers Development Records

Development records for harness-kit itself.

- `specs/` holds the specs of work that has started or shipped. Specs are living
  documents while their effort is open and become immutable historical records
  when it closes.
- `plans/<topic>/journal.md` records what was done, finished or not, as dated
  entries. It is the only other tracked development record.
- Local-only: draft specs and analyses for work that has not started (keep them
  in `plans/<topic>/` and move the spec to `specs/` in the first commit that
  implements it), plans, `reviews/`, `archive/`, every other development-record
  directory and `.agents/` task packets and evidence. Never stage or push them.
- The root `README.md` in this directory is tracked only to define this policy.

Before committing, verify that the branch diff contains no development
artifact outside `docs/superpowers/specs/` and the plan journals.
