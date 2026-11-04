<!-- BEGIN MANAGED: multi-agent-bootstrap:tool-contract -->
Claude Code runs the fast close-out check through its
Stop hook when the session changed files; still run
`scripts/agent-guard.sh pre-final --run-verify` before a hand-off the hook does
not cover. The hooks guard files and context; they are not a security boundary
for arbitrary Bash commands.
<!-- END MANAGED: multi-agent-bootstrap:tool-contract -->
