#!/usr/bin/env python3
"""Focused integration checks for the generated agent-seats launcher.

The suite creates disposable generated projects and puts a recording fake
``codex`` first on PATH.  It never invokes a real Codex binary.  ``--red`` is
the pre-change probe: it records the requested seat behavior that the legacy
generator does not provide.
"""

from __future__ import annotations

import argparse
import copy
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple


ROOT = Path(__file__).resolve().parents[1]
BOOTSTRAP = ROOT / "agent-bootstrap" / "bootstrap-multi-agent-project.sh"
EVIDENCE = (
    ROOT
    / ".agents"
    / "tasks"
    / "agent-seats"
    / "evidence"
    / "release-20260908"
    / "launcher"
)


class CheckFailure(AssertionError):
    pass


def check(condition: bool, message: str) -> None:
    if not condition:
        raise CheckFailure(message)


def run(
    argv: Sequence[str],
    *,
    cwd: Optional[Path] = None,
    env: Optional[Dict[str, str]] = None,
    timeout: int = 30,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        list(argv),
        cwd=str(cwd) if cwd else None,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        check=False,
    )


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def seats_document() -> dict:
    catalog = {
        "gpt-6-astra": {
            "host": "codex",
            "efforts": ["none", "low", "medium", "high", "xhigh", "ultra"],
            "default_effort": "ultra",
        },
        "gpt-5.6-luna": {
            "host": "codex",
            "efforts": ["none", "low", "medium", "high", "xhigh", "max"],
            "default_effort": "xhigh",
        },
        "gpt-5.6-terra": {
            "host": "codex",
            "efforts": ["none", "low", "medium", "high", "xhigh", "max"],
            "default_effort": "xhigh",
        },
        "gpt-5.4": {
            "host": "codex",
            "efforts": ["none", "low", "medium", "high"],
            "default_effort": "high",
        },
        "custom-coder": {
            "host": "codex",
            "efforts": ["medium", "high", "xhigh"],
            "default_effort": "xhigh",
        },
        "global-model": {
            "host": "codex",
            "efforts": ["none", "low", "medium", "high", "xhigh", "max"],
            "default_effort": "medium",
        },
    }
    entries = {
        "spec": {
            "tag": "@spec",
            "phase": "analysis",
            "occupant": {"host": "codex", "model": "gpt-5.6-luna", "effort": "xhigh"},
        },
        "gate": {
            "tag": "@gate",
            "phase": "technical_review",
            "occupant": {
                "host": "codex",
                "model": "gpt-6-astra",
                "effort": "ultra",
                "fallback_model": "gpt-5.6-terra",
                "fallback_effort": "xhigh",
            },
        },
        "build": {
            "tag": "@build",
            "phase": "implementation",
            "occupant": {
                "host": "codex",
                "model": "gpt-5.6-luna",
                "effort": "xhigh",
                "fallback_model": "gpt-5.6-terra",
                "fallback_effort": "xhigh",
            },
        },
        "verify": {
            "tag": "@verify",
            "phase": "verification",
            "occupant": {
                "host": "codex",
                "model": "gpt-6-astra",
                "effort": "ultra",
                "fallback_model": "gpt-5.6-terra",
                "fallback_effort": "xhigh",
            },
        },
        "audit": {
            "tag": "@audit",
            "phase": "cross_review",
            "occupant": {"host": "codex", "model": "gpt-5.6-terra", "effort": "xhigh"},
        },
        "owner": {
            "tag": "@owner",
            "phase": "resolution",
            "occupant": {"host": "human"},
        },
    }
    return {"schema": "agent-seats/v1", "catalog": {"models": catalog}, "seats": entries}


def legacy_document() -> dict:
    return {
        "schema": "agent-model-profiles/v1",
        "default_profile": "default",
        "profiles": {
            "default": {
                "reasoning_effort": "high",
                "planning_model": "gpt-6-astra",
                "coding_model": "gpt-5.6-luna",
                "reviewing_model": "gpt-6-astra",
                "planning_fallback_model": "gpt-5.6-terra",
                "coding_fallback_model": "gpt-5.6-terra",
                "reviewing_fallback_model": "gpt-5.6-terra",
            }
        },
    }


def make_fake_tools(work: Path) -> Tuple[Path, Path, Path]:
    fake_bin = work / "fake-bin"
    fake_bin.mkdir()
    codex_log = work / "codex-argv.log"
    hook_log = work / "hook-argv.log"
    (fake_bin / "codex").write_text(
        "#!/usr/bin/env bash\n"
        ": > \"$CODEX_CAPTURE_FILE\"\n"
        "for arg in \"$@\"; do printf '%s\\n' \"$arg\" >> \"$CODEX_CAPTURE_FILE\"; done\n"
        "printf 'FAKE CODEX\\n'\n",
        encoding="utf-8",
    )
    (fake_bin / "codex").chmod(0o755)
    return fake_bin, codex_log, hook_log


def install_hook_stub(target: Path, hook_log: Path) -> None:
    hook = target / "scripts" / "agent-hook.sh"
    hook.write_text(
        "#!/usr/bin/env bash\n"
        "if [[ \"$1\" == no-scan-paths ]]; then\n"
        "  printf '%s\\n' '.claude/worktrees/ .gemini/ .openclaude/ AGENTS.local.md *.jks'\n"
        "  exit 0\n"
        "fi\n"
        "if [[ \"$1\" == codex-preflight ]]; then\n"
        "  printf '%s\\n' \"$*\" >> \"$HOOK_CAPTURE_FILE\"\n"
        "  printf '%s\\n' \"$*\" >> \"$HOOK_PREFLIGHT_CAPTURE_FILE\"\n"
        "  if [[ \"${2:-}\" != --check-only ]]; then\n"
        "    printf 'mutated by non-check-only preflight\\n' > \"$HOOK_CONTEXT_PACK_FILE\"\n"
        "  fi\n"
        "  exit 0\n"
        "fi\n"
        "printf '%s\\n' \"$*\" >> \"$HOOK_CAPTURE_FILE\"\n"
        "exit 0\n",
        encoding="utf-8",
    )
    hook.chmod(0o755)


def generate_target(work: Path) -> Path:
    target = work / "generated-target"
    target.mkdir()
    result = run(
        [
            "/bin/bash",
            str(BOOTSTRAP),
            "--target",
            str(target),
            "--workflow",
            "full",
            "--force",
            "--no-backup",
        ],
        cwd=ROOT,
        timeout=60,
    )
    check(
        result.returncode == 0,
        "full generator failed before launcher checks:\n"
        + result.stdout[-4000:]
        + result.stderr[-4000:],
    )
    installed = target / "scripts" / "agent-seats.sh"
    seats = target / "docs" / "agent-configs" / "seats.json"
    canonical = ROOT / "agent-bootstrap" / "agent-seats.sh"
    check(installed.is_file() and os.access(installed, os.X_OK), "generator did not emit executable scripts/agent-seats.sh")
    check(installed.read_bytes() == canonical.read_bytes(), "generated agent-seats.sh drifted from the canonical bundle")
    check(seats.is_file(), "generator did not initialize docs/agent-configs/seats.json")
    write_json(seats, seats_document())
    return target


def base_env(fake_bin: Path, codex_log: Path, hook_log: Path) -> Dict[str, str]:
    env = os.environ.copy()
    for key in list(env):
        if key.startswith("CODEX_"):
            del env[key]
    env["PATH"] = str(fake_bin) + os.pathsep + env.get("PATH", "")
    env["CODEX_CAPTURE_FILE"] = str(codex_log)
    env["HOOK_CAPTURE_FILE"] = str(hook_log)
    env["HOOK_PREFLIGHT_CAPTURE_FILE"] = str(hook_log.with_name("hook-preflight.log"))
    env["HOOK_CONTEXT_PACK_FILE"] = str(hook_log.with_name("context-pack.json"))
    return env


def launcher(target: Path) -> Path:
    path = target / ".codex" / "codex-mode.sh"
    check(path.exists(), "generated launcher is missing")
    return path


def clear_capture(codex_log: Path, hook_log: Path) -> None:
    for path in (codex_log, hook_log):
        if path.exists():
            path.unlink()


def invoke(
    target: Path,
    args: Sequence[str],
    env: Dict[str, str],
    *,
    trap: bool = False,
) -> subprocess.CompletedProcess[str]:
    clear_capture(Path(env["CODEX_CAPTURE_FILE"]), Path(env["HOOK_CAPTURE_FILE"]))
    command: List[str]
    if trap:
        trap_path = Path(env["TRAP_CAPTURE_FILE"])
        command = [
            "/bin/bash",
            "-c",
            'trap \'printf trapped > "$TRAP_CAPTURE_FILE"\' EXIT; "$@"',
            "launcher-caller",
            str(launcher(target)),
        ] + list(args)
    else:
        command = [str(launcher(target))] + list(args)
    return run(command, cwd=target, env=env, timeout=35)


def captured_args(codex_log: Path) -> List[str]:
    check(codex_log.exists(), "fake Codex was not invoked")
    return codex_log.read_text(encoding="utf-8").splitlines()


def arg_value(args: Iterable[str], flag: str) -> str:
    values = list(args)
    check(flag in values, f"fake Codex argv has no {flag}: {values}")
    return values[values.index(flag) + 1]


def assert_no_launch(result: subprocess.CompletedProcess[str], codex_log: Path) -> None:
    check(result.returncode != 0, "expected launcher refusal, got rc 0")
    check(not codex_log.exists(), "Codex was invoked after launcher refusal")


def assert_no_temp_leaks(target: Path) -> None:
    leaked = [p for p in target.rglob("*") if ".tmp" in p.name or p.name.endswith(".launcher-capture")]
    check(not leaked, "launcher left temporary files: " + ", ".join(map(str, leaked)))


def edit_seat(target: Path, seat: str, occupant: dict) -> None:
    path = target / "docs" / "agent-configs" / "seats.json"
    document = json.loads(path.read_text(encoding="utf-8"))
    document["seats"][seat]["occupant"] = occupant
    write_json(path, document)


def test_generated_surface(target: Path) -> None:
    text = launcher(target).read_text(encoding="utf-8")
    check("while IFS= read -r" in text, "launcher lacks the lossless line reader")
    check("model-info" in text, "launcher lacks the three-line model-info lookup")
    check('agent-seats.sh efforts' not in text, "launcher still calls the removed efforts subcommand")
    check("launch_model=" in text and "model_source=" in text, "launcher seed lost model provenance")
    check("actual_model=" not in text, "launcher seed still labels an unconfirmed model as actual")
    agents = (target / "AGENTS.md").read_text(encoding="utf-8")
    check("multi-agent-bootstrap:seat-roster" in agents, "AGENTS.md has no managed seat roster")
    check("scripts/agent-seats.sh" in agents, "AGENTS.md has no seat operator pointer")

    mode = (target / "docs" / "agent-configs" / "agent-mode-contracts.md").read_text(encoding="utf-8")
    handoff = (target / "docs" / "agent-configs" / "agent-handoff-schema.md").read_text(encoding="utf-8")
    prose_paths = [
        target / "CLAUDE.md",
        target / ".claude" / "README.md",
        target / ".claude" / "commands" / "coding.md",
        target / ".claude" / "commands" / "codex" / "rescue.md",
        target / ".codex" / "README.md",
    ]
    prose = "\n".join(path.read_text(encoding="utf-8") for path in prose_paths)
    for tag in ("@spec", "@gate", "@build", "@verify", "@audit", "@owner"):
        check(tag in mode + handoff + prose + agents, f"generated prose omits {tag}")
    for field in ("seat", '"occupant"', 'owner: agent', "runner_host", '"runner": "agent"'):
        check(field in handoff, f"handoff prose omits {field}")
    for path in (
        target / "docs" / "agent-configs" / "agent-handoff-schema.md",
        target / "docs" / "agent-configs" / "agent-mode-contracts.md",
        target / "docs" / "agent-configs" / "karpathy-llm-coding-agent-config.md",
        target / "docs" / "agent-configs" / "llm-council-agent-workflow.md",
    ):
        content = path.read_text(encoding="utf-8")
        check("Config version:" not in content, f"budget compensation line remains in {path}")
    for word in ("Sol", "Luna", "Astra"):
        check(word not in mode + handoff + prose, f"role word remains in generated prose: {word}")


def test_resolve_and_model_info(target: Path, env: Dict[str, str]) -> None:
    seats = ("@spec", "spec", "@gate", "gate", "@build", "build", "@verify", "verify", "@audit", "audit")
    for name in seats:
        result = run([str(target / "scripts" / "agent-seats.sh"), "resolve", name], cwd=target, env=env)
        check(result.returncode == 0, f"resolve {name} failed: {result.stderr}")
        check(len(result.stdout.splitlines()) == 8, f"resolve {name} did not return eight lines: {result.stdout!r}")
    warning_result = run(
        [str(target / ".codex" / "codex-mode.sh"), "status"],
        cwd=target,
        env={**env, "CODEX_MODEL_PROFILE": "legacy"},
    )
    check(warning_result.returncode == 0, "valid status failed while emitting its warning")
    check("warn" in warning_result.stderr.lower(), "valid status did not expose its warning on stderr")
    check("warn" not in warning_result.stdout.lower(), "valid status mixed diagnostics into stdout")
    result = run(
        [str(target / "scripts" / "agent-seats.sh"), "model-info", "gpt-5.6-luna"],
        cwd=target,
        env=env,
    )
    check(result.returncode == 0, f"model-info failed: {result.stderr}")
    check(result.stdout.splitlines() == ["codex", "xhigh", "none low medium high xhigh max"], "model-info contract changed")
    check("efforts" not in result.stdout, "model-info emitted a legacy command label")


def test_launch_matrix(target: Path, env: Dict[str, str], codex_log: Path, hook_log: Path) -> None:
    expected = {
        "planning": ("gpt-6-astra", "ultra", "planning"),
        "@gate": ("gpt-6-astra", "ultra", "planning"),
        "gate": ("gpt-6-astra", "ultra", "planning"),
        "coding": ("gpt-5.6-luna", "xhigh", "coding"),
        "@build": ("gpt-5.6-luna", "xhigh", "coding"),
        "build": ("gpt-5.6-luna", "xhigh", "coding"),
        "reviewing": ("gpt-6-astra", "ultra", "reviewing"),
        "@verify": ("gpt-6-astra", "ultra", "reviewing"),
        "verify": ("gpt-6-astra", "ultra", "reviewing"),
        "@spec": ("gpt-5.6-luna", "xhigh", "planning"),
        "spec": ("gpt-5.6-luna", "xhigh", "planning"),
        "@audit": ("gpt-5.6-terra", "xhigh", "reviewing"),
        "audit": ("gpt-5.6-terra", "xhigh", "reviewing"),
    }
    for name, (model, effort, route) in expected.items():
        result = invoke(target, [name], env)
        check(result.returncode == 0, f"launch {name} failed: {result.stderr}")
        args = captured_args(codex_log)
        check(arg_value(args, "--model") == model, f"{name} selected the wrong model")
        check(f'model_reasoning_effort="{effort}"' in args, f"{name} selected the wrong effort")
        hook = hook_log.read_text(encoding="utf-8")
        check(route in hook.splitlines()[-1], f"{name} did not map to route {route} for the hook")

    result = invoke(target, ["@build", "--supervised", "bounded prompt"], env)
    check(result.returncode == 0, "supervised launch failed")
    args = captured_args(codex_log)
    check(arg_value(args, "-s") == "read-only", "supervised launch changed sandbox behavior")
    check(arg_value(args, "-a") == "on-request", "supervised launch changed approval behavior")

    result = invoke(target, ["@build", "--full-flow"], env)
    check(result.returncode == 0, "full-flow launch failed")
    args = captured_args(codex_log)
    check(arg_value(args, "-s") == "workspace-write", "full-flow launch changed sandbox behavior")
    check(arg_value(args, "-a") == "never", "full-flow launch changed approval behavior")

    for seat, flow_flag in (
        ("@gate", "--supervised"),
        ("@gate", "--full-flow"),
        ("@build", "--supervised"),
        ("@build", "--full-flow"),
        ("@verify", "--supervised"),
        ("@verify", "--full-flow"),
    ):
        result = invoke(target, [seat, flow_flag], env)
        check(result.returncode == 0, f"seed variant {seat} {flow_flag} failed")
        seed = "\n".join(captured_args(codex_log))
        check("docs/agent-configs/agent-mode-contracts.md" in seed, f"seed variant {seat} {flow_flag} lost mode contract pointer")
        check("docs/agent-configs/agent-handoff-schema.md" in seed, f"seed variant {seat} {flow_flag} lost handoff schema pointer")
        if seat == "@verify":
            check(
                "Severity must name its trigger condition and frequency, or mark itself as an estimate." in seed,
                f"seed variant {seat} {flow_flag} lost severity trigger obligation",
            )

    result = invoke(target, ["@build"], {**env, "CODEX_USE_FALLBACK": "1"})
    check(result.returncode == 0, "fallback launch failed")
    args = captured_args(codex_log)
    check(arg_value(args, "--model") == "gpt-5.6-terra", "fallback selected the wrong model")
    check('model_reasoning_effort="xhigh"' in args, "fallback selected the wrong effort")

    result = invoke(target, ["@build"], {**env, "CODEX_MODEL_OVERRIDE": "gpt-5.4"})
    check(result.returncode == 0, "model override launch failed")
    args = captured_args(codex_log)
    check(arg_value(args, "--model") == "gpt-5.4", "override selected the wrong model")
    check('model_reasoning_effort="high"' in args, "override did not use catalog default effort")
    check("Model source: CODEX_MODEL_OVERRIDE" in result.stderr, "override source was not retained in launch summary")

    result = invoke(target, ["@build"], {**env, "CODEX_CODING_MODEL_OVERRIDE": "custom-coder"})
    check(result.returncode == 0, "route-named model override launch failed")
    args = captured_args(codex_log)
    check(arg_value(args, "--model") == "custom-coder", "route-named override selected the wrong model")
    check("Model source: CODEX_CODING_MODEL_OVERRIDE" in result.stderr, "route-named override source was not retained")

    result = invoke(target, ["@build"], {**env, "CODEX_REASONING_EFFORT": "low"})
    check(result.returncode == 0, "valid explicit effort failed")
    check('model_reasoning_effort="low"' in captured_args(codex_log), "explicit effort was ignored")

    result = invoke(target, ["@build"], {**env, "CODEX_REASONING_EFFORT": "ultra"})
    assert_no_launch(result, codex_log)
    check("supported" in result.stderr and "xhigh" in result.stderr, "invalid effort lacks catalog guidance")
    mode_file = target / ".codex-mode-lock"
    mode_before = mode_file.read_bytes() if mode_file.exists() else None
    for invalid_effort in ("high xhigh", "xhigh max", " xhigh", "xhigh "):
        result = invoke(target, ["@build"], {**env, "CODEX_REASONING_EFFORT": invalid_effort})
        assert_no_launch(result, codex_log)
        check("effort" in result.stderr.lower(), f"invalid multiword effort lacked diagnostics: {invalid_effort!r}")
        mode_after = mode_file.read_bytes() if mode_file.exists() else None
        check(mode_after == mode_before, f"invalid effort changed persisted mode: {invalid_effort!r}")

    result = invoke(target, ["@spec"], {**env, "CODEX_USE_FALLBACK": "1"})
    assert_no_launch(result, codex_log)
    check("fallback" in result.stderr.lower(), "missing fallback refusal lacks guidance")

    result = invoke(target, ["@build"], {**env, "CODEX_MODEL_OVERRIDE": "unknown-model"})
    assert_no_launch(result, codex_log)
    check("catalog" in result.stderr, "unknown override lacks catalog guidance")


def test_conflict_and_non_codex(target: Path, env: Dict[str, str], codex_log: Path) -> None:
    edit_seat(
        target,
        "build",
        {
            "host": "codex",
            "model": "gpt-6-astra",
            "effort": "ultra",
            "fallback_model": "gpt-5.6-terra",
            "fallback_effort": "xhigh",
        },
    )
    result = invoke(target, ["@build"], env)
    check(result.returncode == 0, "conflicting build launch was refused")
    marker = "policy_exception=gate_coding authorization=user_session"
    check(marker in result.stderr, "conflicting build launch omitted the policy exception")

    result = invoke(target, ["@build"], {**env, "CODEX_MODEL_OVERRIDE": "gpt-5.4"})
    check(result.returncode == 0, "override-away conflict launch failed")
    check(marker not in result.stderr, "conflict was calculated from the declared model")

    edit_seat(
        target,
        "build",
        {
            "host": "codex",
            "model": "gpt-5.6-luna",
            "effort": "xhigh",
            "fallback_model": "gpt-5.6-terra",
            "fallback_effort": "xhigh",
        },
    )
    result = invoke(target, ["@build"], {**env, "CODEX_MODEL_OVERRIDE": "gpt-6-astra"})
    check(result.returncode == 0 and marker in result.stderr, "override-into conflict was not audited")

    edit_seat(target, "spec", {"host": "claude"})
    result = invoke(target, ["@spec"], env)
    check(result.returncode == 2, "non-Codex seat did not return rc 2")
    check("occupied by claude" in result.stderr, "non-Codex refusal lacks host guidance")
    check(not codex_log.exists(), "non-Codex seat launched Codex")

    edit_seat(target, "spec", {"host": "codex", "model": "gpt-5.6-luna", "effort": "xhigh"})
    result = invoke(target, ["@owner"], env)
    check(result.returncode == 2 and not codex_log.exists(), "@owner was launchable")


def test_read_only_and_auto_init(target: Path, env: Dict[str, str], codex_log: Path) -> None:
    seats = target / "docs" / "agent-configs" / "seats.json"
    legacy = target / "docs" / "agent-configs" / "model-profiles.json"
    saved = seats.read_bytes()
    if legacy.exists():
        legacy_saved = legacy.read_bytes()
    else:
        legacy_saved = None
    seats.unlink()
    if legacy.exists():
        legacy.unlink()
    status = invoke(target, ["status"], env)
    check(status.returncode == 0, "status failed on missing seats")
    check("WARN" in status.stdout or "warn" in status.stdout.lower() or "warn" in status.stderr.lower(), "status did not warn on missing seats")
    check(not seats.exists(), "status auto-seeded seats.json")
    doctor = invoke(target, ["doctor"], env)
    check(doctor.returncode == 0, "doctor failed on missing seats")
    check(not seats.exists(), "doctor auto-seeded seats.json")

    seats.write_text("{ malformed\n", encoding="utf-8")
    invalid_status = invoke(target, ["status"], env)
    check(invalid_status.returncode != 0, "status accepted malformed seats")
    invalid_doctor = invoke(target, ["doctor"], env)
    check(invalid_doctor.returncode != 0, "doctor accepted malformed seats")
    check(seats.read_text(encoding="utf-8") == "{ malformed\n", "read-only command rewrote malformed seats")

    seats.write_bytes(saved)
    if legacy_saved is not None:
        legacy.write_bytes(legacy_saved)
    else:
        legacy.write_text(json.dumps(legacy_document()) + "\n", encoding="utf-8")
    seats.unlink()
    launch = invoke(target, ["@build"], env)
    check(launch.returncode == 0, "launch auto-init failed")
    check(seats.exists(), "launch did not auto-seed missing seats")
    check(arg_value(captured_args(codex_log), "--model") == "gpt-5.6-luna", "auto-init selected the wrong seat")

    seats.write_bytes(saved)
    legacy.write_text("{ malformed legacy\n", encoding="utf-8")
    valid_status = invoke(target, ["status"], env)
    check(valid_status.returncode == 0, "status let malformed inactive legacy override valid seats")
    valid_doctor = invoke(target, ["doctor"], env)
    check(valid_doctor.returncode == 0, "doctor let malformed inactive legacy override valid seats")
    if legacy_saved is None:
        legacy.unlink()
    else:
        legacy.write_bytes(legacy_saved)


def test_active_invalid_seats(target: Path, env: Dict[str, str]) -> None:
    seats = target / "docs" / "agent-configs" / "seats.json"
    saved = seats.read_bytes()
    cases = []
    cases.append(("missing seat", {"schema": "agent-seats/v1", "catalog": {"models": {}}, "seats": {}}, "seat gate: missing"))
    invalid = seats_document()
    invalid["seats"]["gate"]["occupant"]["model"] = "unknown-model"
    cases.append(("unknown model", invalid, "unknown-model"))
    invalid = seats_document()
    invalid["seats"]["gate"]["occupant"]["effort"] = "turbo"
    cases.append(("unsupported effort", invalid, "turbo"))
    invalid = seats_document()
    invalid["seats"]["gate"]["occupant"].pop("fallback_model")
    cases.append(("orphan fallback effort", invalid, "fallback_effort without fallback_model"))
    try:
        for label, document, detail in cases:
            write_json(seats, document)
            result = run([str(target / "scripts" / "agent-seats.sh"), "validate"], cwd=target, env=env)
            check(result.returncode == 1, f"active invalid seats case {label} was accepted")
            check("agent-seats: ERROR:" in result.stderr, f"active invalid seats case {label} lost the error prefix")
            check(detail in result.stderr, f"active invalid seats case {label} lost diagnostic detail")
    finally:
        seats.write_bytes(saved)


def test_doctor_and_non_codex_status(target: Path, env: Dict[str, str]) -> None:
    seats = target / "docs" / "agent-configs" / "seats.json"
    (target / ".codex-mode-lock").write_text(
        "mode=planning\nflow=full_flow\nseat=gate\nupdated_at=fixture\n",
        encoding="utf-8",
    )
    context_pack = Path(env["HOOK_CONTEXT_PACK_FILE"])
    context_pack.parent.mkdir(parents=True, exist_ok=True)
    seeded = run([str(target / "scripts" / "agent-guard.sh"), "preflight"], cwd=target, env=env)
    check(seeded.returncode == 0, "could not seed a valid guard context pack")
    before_context_pack = context_pack.read_bytes()
    doctor = invoke(target, ["doctor"], env)
    check(doctor.returncode == 0, "doctor failed on a valid roster")
    check(context_pack.read_bytes() == before_context_pack, "doctor preflight rewrote guard state")
    preflight = Path(env["HOOK_PREFLIGHT_CAPTURE_FILE"]).read_text(encoding="utf-8")
    check("codex-preflight --check-only" in preflight, "doctor omitted --check-only preflight")
    for tag in ("@spec", "@gate", "@build", "@verify", "@audit", "@owner"):
        check(tag in doctor.stdout, f"doctor roster omitted {tag}")
    check("locked @gate: model=gpt-6-astra effort=ultra source=default" in doctor.stdout, "doctor omitted locked effective model details")
    check("project brief is unfilled" in doctor.stdout, "doctor omitted the unfilled project brief warning")

    saved = seats.read_bytes()
    try:
        edit_seat(target, "gate", {"host": "claude"})
        status = invoke(target, ["status"], env)
        check(status.returncode == 0, "status refused a valid non-Codex locked seat")
        check("Locked occupant: claude" in status.stdout, "status omitted the non-Codex locked host")
        check("ERROR:" not in status.stderr, "valid host-controlled status emitted a launch-refusal error")
        doctor = invoke(target, ["doctor"], env)
        check(doctor.returncode == 0, "doctor refused a valid non-Codex locked seat")
        check("locked @gate: host=claude" in doctor.stdout, "doctor omitted the non-Codex locked host")
        check("ERROR:" not in doctor.stderr, "valid host-controlled doctor emitted a launch-refusal error")
    finally:
        seats.write_bytes(saved)


def test_persistence_nested_and_failures(target: Path, env: Dict[str, str], codex_log: Path) -> None:
    mode_file = target / ".codex-mode-lock"
    if mode_file.exists():
        mode_file.unlink()
    result = invoke(target, ["coding"], env, trap=True)
    check(result.returncode == 0, "persistent coding launch failed")
    check(mode_file.exists() and "mode=coding" in mode_file.read_text(encoding="utf-8"), "coding did not persist mode")
    check(Path(env["TRAP_CAPTURE_FILE"]).exists(), "caller EXIT trap was lost")
    result = invoke(target, ["run"], env)
    check(result.returncode == 0, "run did not use persisted mode")
    check(arg_value(captured_args(codex_log), "--model") == "gpt-5.6-luna", "run selected the wrong persisted seat")

    nested = invoke(target, ["@build"], {**env, "CODEX_HARNESS_SESSION": "1"})
    assert_no_launch(nested, codex_log)
    check("nested" in nested.stderr.lower(), "nested launch refusal lacks guidance")

    seats = target / "docs" / "agent-configs" / "seats.json"
    saved = seats.read_bytes()
    seats.write_text("{ malformed\n", encoding="utf-8")
    malformed = invoke(target, ["@build"], env)
    assert_no_launch(malformed, codex_log)
    check("json" in malformed.stderr.lower() or "malformed" in malformed.stderr.lower(), "malformed JSON lacks diagnostics")
    seats.write_bytes(saved)

    python_fail = target.parent / "python-failure-bin"
    python_fail.mkdir(exist_ok=True)
    (python_fail / "python3").write_text("#!/usr/bin/env bash\necho python-failure >&2\nexit 42\n", encoding="utf-8")
    (python_fail / "python3").chmod(0o755)
    failed_python = invoke(target, ["@build"], {**env, "PATH": str(python_fail) + os.pathsep + env["PATH"]})
    assert_no_launch(failed_python, codex_log)
    check("python" in failed_python.stderr.lower(), "Python failure lacks diagnostics")

    invalid_effort = invoke(target, ["@build"], {**env, "CODEX_REASONING_EFFORT": "not-an-effort"})
    assert_no_launch(invalid_effort, codex_log)
    check("effort" in invalid_effort.stderr.lower(), "invalid effort lacks diagnostics")
    assert_no_temp_leaks(target)


def patch_launcher(path: Path, mutation: str) -> None:
    text = path.read_text(encoding="utf-8")
    if mutation == "merge-stderr":
        needle = '2>"$error_file"'
        check(needle in text, "merge-stderr mutation boundary is absent")
        text = text.replace(needle, "2>&1", 1)
    elif mutation == "bypass-conflict":
        needle = '"$SEATS_SCRIPT" conflict "$seat_id" "$effective_model" 2>"$conflict_stderr"'
        check(needle in text, "conflict mutation boundary is absent")
        text = text.replace(needle, 'printf "%s\\n" "0"', 1)
    elif mutation == "skip-explicit-effort":
        needle = 'validate_explicit_effort "$EFFECTIVE_MODEL" "$explicit_effort" "$supported_efforts"'
        check(needle in text, "explicit effort mutation boundary is absent")
        text = text.replace(needle, ": # mutation skips explicit effort validation", 1)
    else:
        raise CheckFailure(f"unknown mutation {mutation}")
    path.write_text(text, encoding="utf-8")


def mutation_target(base_target: Path, work: Path, mutation: str) -> Path:
    target = work / ("mutant-" + mutation)
    shutil.copytree(base_target, target)
    patch_launcher(target / ".codex" / "codex-mode.sh", mutation)
    return target


def test_mutations(base_target: Path, work: Path, env: Dict[str, str]) -> List[str]:
    caught: List[str] = []
    marker = "policy_exception=gate_coding authorization=user_session"
    for mutation in ("merge-stderr", "bypass-conflict", "skip-explicit-effort"):
        target = mutation_target(base_target, work, mutation)
        mutant_env = dict(env)
        mutant_env["CODEX_CAPTURE_FILE"] = str(work / (mutation + ".codex.log"))
        mutant_env["HOOK_CAPTURE_FILE"] = str(work / (mutation + ".hook.log"))
        if mutation == "merge-stderr":
            seats_script = target / "scripts" / "agent-seats.sh"
            real = target / "scripts" / "agent-seats.real.sh"
            seats_script.rename(real)
            seats_script.write_text(
                "#!/usr/bin/env bash\n"
                "if [[ \"$1\" == resolve ]]; then echo boundary-warning >&2; fi\n"
                "exec \"$(dirname \"$0\")/agent-seats.real.sh\" \"$@\"\n",
                encoding="utf-8",
            )
            seats_script.chmod(0o755)
            result = invoke(target, ["@build"], mutant_env)
            try:
                check(result.returncode == 0, "merged resolve diagnostics were accepted")
            except CheckFailure:
                caught.append(mutation)
                continue
            raise CheckFailure("merge-stderr mutant was not caught by eight-line validation")
        elif mutation == "bypass-conflict":
            edit_seat(
                target,
                "build",
                {
                    "host": "codex",
                    "model": "gpt-6-astra",
                    "effort": "ultra",
                    "fallback_model": "gpt-5.6-terra",
                    "fallback_effort": "xhigh",
                },
            )
            result = invoke(target, ["@build"], mutant_env)
            try:
                check(result.returncode == 0, "conflicting launch was refused")
                check(marker in result.stderr, "conflicting launch omitted the policy exception")
            except CheckFailure:
                caught.append(mutation)
                continue
            raise CheckFailure("bypass-conflict mutant was not caught")
        else:
            result = invoke(
                target,
                ["@build"],
                {**mutant_env, "CODEX_REASONING_EFFORT": "ultra"},
            )
            try:
                check(result.returncode != 0, "invalid explicit effort was accepted")
                check(not Path(mutant_env["CODEX_CAPTURE_FILE"]).exists(), "Codex launched with invalid explicit effort")
            except CheckFailure:
                caught.append(mutation)
                continue
            raise CheckFailure("skip-explicit-effort mutant was not caught")
    return caught


def run_red() -> int:
    failures: List[str] = []
    with tempfile.TemporaryDirectory(prefix="agent-seats-red-") as raw:
        work = Path(raw)
        target = work / "old-target"
        target.mkdir()
        result = run(
            [
                "/bin/bash",
                str(BOOTSTRAP),
                "--target",
                str(target),
                "--workflow",
                "full",
                "--force",
                "--no-backup",
            ],
            cwd=ROOT,
            timeout=60,
        )
        if result.returncode != 0:
            failures.append("old generator could not produce a full target: " + result.stderr[-1000:])
        else:
            generated = target / ".codex" / "codex-mode.sh"
            content = generated.read_text(encoding="utf-8") if generated.exists() else ""
            probes = {
                "five seat tags": all(tag in content for tag in ("@spec", "@gate", "@build", "@verify", "@audit")),
                "lossless eight-line reader": "while IFS= read -r" in content,
                "model-info lookup": "model-info" in content,
                "launch_model seed": "launch_model=" in content,
                "gate_coding audit": "gate_coding" in content,
                "CODEX_MODEL_PROFILE warning no-op": "warning" in content and "CODEX_MODEL_PROFILE" in content,
            }
            failures.extend(name for name, passed in probes.items() if passed is False)
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    (EVIDENCE / "red-old-generator.json").write_text(
        json.dumps({"generator": str(BOOTSTRAP), "failures": failures, "expected": "RED"}, indent=2) + "\n",
        encoding="utf-8",
    )
    print("RED old-generator failures: " + ", ".join(failures))
    return 1 if failures else 0


def run_green(run_mutations: bool) -> int:
    results: Dict[str, object] = {"status": "running", "tests": {}, "mutations": []}
    with tempfile.TemporaryDirectory(prefix="agent-seats-launcher-") as raw:
        work = Path(raw)
        target = generate_target(work)
        fake_bin, codex_log, hook_log = make_fake_tools(work)
        install_hook_stub(target, hook_log)
        env = base_env(fake_bin, codex_log, hook_log)
        env["HOOK_CONTEXT_PACK_FILE"] = str(target / ".agents" / "state" / "context-pack.json")
        env["TRAP_CAPTURE_FILE"] = str(work / "caller-exit-trap")
        tests = [
            ("generated_surface", lambda: test_generated_surface(target)),
            ("resolve_and_model_info", lambda: test_resolve_and_model_info(target, env)),
            ("launch_matrix", lambda: test_launch_matrix(target, env, codex_log, hook_log)),
            ("conflict_and_non_codex", lambda: test_conflict_and_non_codex(target, env, codex_log)),
            ("read_only_and_auto_init", lambda: test_read_only_and_auto_init(target, env, codex_log)),
            ("active_invalid_seats", lambda: test_active_invalid_seats(target, env)),
            ("doctor_and_non_codex_status", lambda: test_doctor_and_non_codex_status(target, env)),
            ("persistence_nested_and_failures", lambda: test_persistence_nested_and_failures(target, env, codex_log)),
        ]
        for name, test in tests:
            try:
                test()
            except Exception as exc:  # preserve every failure in the evidence report
                results["tests"][name] = {"status": "FAIL", "detail": str(exc)}  # type: ignore[index]
                raise
            else:
                results["tests"][name] = {"status": "PASS"}  # type: ignore[index]
        if run_mutations:
            results["mutations"] = test_mutations(target, work, env)
        else:
            results["mutations"] = "skipped (pass --mutations to run isolated mutant fixtures)"
        results["status"] = "PASS"
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    (EVIDENCE / "launcher-results.json").write_text(json.dumps(results, indent=2) + "\n", encoding="utf-8")
    mutation_note = ", 3 mutations caught" if run_mutations else ""
    print(f"GREEN launcher integration: 8 test groups{mutation_note}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--red", action="store_true", help="record expected failures against the old generator")
    parser.add_argument("--mutations", action="store_true", help="run the three isolated launcher mutation fixtures")
    args = parser.parse_args()
    try:
        return run_red() if args.red else run_green(args.mutations)
    except (CheckFailure, subprocess.TimeoutExpired) as exc:
        EVIDENCE.mkdir(parents=True, exist_ok=True)
        (EVIDENCE / "launcher-failure.txt").write_text(str(exc) + "\n", encoding="utf-8")
        print("FAIL: " + str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
