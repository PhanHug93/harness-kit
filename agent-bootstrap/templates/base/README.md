# Base Multi-Agent Template

Portable baseline applied to every bootstrapped project.

Managed sections generated from this template must be bounded by:

```text
<!-- BEGIN MANAGED: multi-agent-bootstrap:<section> -->
<!-- END MANAGED: multi-agent-bootstrap:<section> -->
```

Base rules:

- Keep tool-specific files thin; durable rules live under `docs/agent-configs/`.
- Require runtime stack refresh through `scripts/detect-agent-tech-stack.sh`.
- Require rtk for all shell git operations through `./scripts/rtk git ...`.
- Default planning/coding/reviewing modes are project-local full-flow; use a
  supervised/read-only/propose argument only when the user wants gated actions.
- Use Claude as primary planning owner and Codex as primary coding/review
  owner unless a project-specific override says otherwise.
- Use `docs/agent-configs/agent-handoff-schema.md` for ownership changes and
  rescue handoffs.
- Respect `scripts/agent-hook.sh no-scan-paths` before broad search; the
  tracked-state guard fails on agent/vendor runtime state, personal overrides,
  and local caches, while sensitive project files remain no-scan.
- Track generated detector state in `docs/agent-configs/agent-bootstrap.lock.json`.
