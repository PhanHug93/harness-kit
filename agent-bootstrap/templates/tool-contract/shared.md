<!-- BEGIN MANAGED: multi-agent-bootstrap:tool-contract -->
Read `AGENTS.md` first. Load `docs/agent-configs/project-agent-context.md`, the filled project brief when available, and detector output before substantive work.

At the start of substantive work, run:

```bash
scripts/agent-guard.sh preflight
scripts/detect-agent-tech-stack.sh --markdown
```

Before claiming completion, run:

```bash
scripts/agent-guard.sh pre-final --run-verify
```

Review the detected verification commands before using `--verify-scope full` for release, high-risk, or final PR readiness. Use `scripts/agent-hook.sh no-scan-paths` before broad search. This harness guards files, context freshness, verification, and generated candidates; it is not a security boundary for arbitrary Bash commands.
Claude Code auto-runs fast close-out verification through a Stop hook when the tree has changes; Gemini, Cursor, and Windsurf do not expose an equivalent close-out hook here, so their loop remains advisory and agents must run `scripts/agent-guard.sh pre-final --run-verify` manually.
<!-- END MANAGED: multi-agent-bootstrap:tool-contract -->
