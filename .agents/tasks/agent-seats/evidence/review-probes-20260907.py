#!/usr/bin/env python3
"""Read-only source review; exercise the reference on a disposable target."""
import hashlib
import json
import os
from pathlib import Path
import pty
import select
import shutil
import subprocess
import sys
import tempfile
import time

evidence = Path(__file__).resolve().parent
repo = evidence.parents[3]
out = evidence / (sys.argv[1] if len(sys.argv) > 1 else 'review-attempt1')
out.mkdir(exist_ok=False)
target = Path(tempfile.mkdtemp(prefix='agent-seats-review-')).resolve()
env = dict(os.environ, GIT_OPTIONAL_LOCKS='0')
results = {}
def run(name, args, expected=None):
    r = subprocess.run(args, cwd=target, env=env, text=True, capture_output=True, timeout=45)
    (out / (name + '.stdout')).write_text(r.stdout)
    (out / (name + '.stderr')).write_text(r.stderr)
    results[name] = {'rc': r.returncode, 'args': args}
    if expected is not None:
        assert r.returncode == expected, (name, r.returncode, r.stderr)
    return r
def digest(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()
source_files = [
    '.agents/tasks/agent-seats/task.md',
    '.agents/tasks/agent-seats/build-handoff.md',
    '.agents/tasks/agent-seats/evidence/reference-agent-seats.sh',
    'docs/superpowers/specs/2026-09-06-agent-seats-design.md',
    'agent-bootstrap/lib/writers-docs.sh', 'agent-bootstrap/lib/writers-runtime.sh',
    'agent-bootstrap/lib/core.sh',
]
before = {name: digest(repo / name) for name in source_files}
run('git-init', ['git', 'init', '-q'], 0)
run('bootstrap', ['/bin/bash', str(repo / 'scripts/bootstrap-multi-agent-project.sh'), '--target', str(target), '--workflow', 'full'], 0)
script = target / 'scripts/agent-seats.sh'
shutil.copy2(evidence / 'reference-agent-seats.sh', script)
script.chmod(0o755)
def seats(name, *args, expected=None):
    return run(name, ['/bin/bash', str(script), *args], expected)
run('bash-version', ['/bin/bash', '--version'], 0)
run('shellcheck', ['shellcheck', '--external-sources', '--exclude=SC1090,SC1091,SC2034,SC2154', str(script)])
seats('suggest-fresh', 'suggest', expected=0)
seats('wizard-yes', 'wizard', '--yes', expected=0)
seats('render-1', 'render', expected=0)
agents = target / 'AGENTS.md'
first_render = agents.read_bytes()
seats('render-2', 'render', expected=0)
results['render_idempotent'] = first_render == agents.read_bytes()
config = target / 'docs/agent-configs/seats.json'
legacy = target / 'docs/agent-configs/model-profiles.json'
saved_config = config.read_bytes()
seats('set-invalid-effort', 'set', 'build', '--host', 'codex', '--effort', 'not-supported', expected=1)
results['invalid_set_preserves_config'] = config.read_bytes() == saved_config
seats('resolve-planning', 'resolve', 'planning', expected=0)
seats('validate', 'validate', expected=0)

# A real TTY at the shell boundary, without supplying any answers.
master, slave = pty.openpty()
proc = subprocess.Popen(['/bin/bash', '-c', '[[ -t 0 ]] || exit 99; printf "outer_stdin_is_tty=true\\n"; exec /bin/bash "$1" wizard', 'review-pty', str(script)], cwd=target, env=env, stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
os.close(slave)
chunks = []
deadline = time.monotonic() + 3
while time.monotonic() < deadline:
    ready, _, _ = select.select([master], [], [], 0.1)
    if ready:
        try:
            chunk = os.read(master, 65536)
        except OSError:
            break
        if not chunk:
            break
        chunks.append(chunk)
    elif proc.poll() is not None:
        break
if proc.poll() is None:
    try:
        proc.wait(timeout=0.25)
    except subprocess.TimeoutExpired:
        pass
finished_without_input = proc.poll() is not None
if proc.poll() is None:
    proc.terminate()
proc.wait(timeout=5)
os.close(master)
transcript = b''.join(chunks).decode(errors='replace')
(out / 'wizard-pty.txt').write_text(transcript)
results['wizard_pty'] = {'outer_tty': 'outer_stdin_is_tty=true' in transcript, 'finished_without_input': finished_without_input, 'host_prompt_seen': 'host>' in transcript, 'rc': proc.returncode}

# The handoff's exact Bash reader loses empty optional TSV columns.
doc = json.loads(saved_config)
gate = doc['seats']['gate']['occupant']
doc['seats']['build']['occupant'] = {'host': 'codex', 'model': gate['model'], 'effort': gate['effort']}
config.write_text(json.dumps(doc))
seats('validate-no-fallback', 'validate', expected=0)
row = seats('resolve-no-fallback', 'resolve', 'build', expected=0).stdout
results['resolve_no_fallback_fields'] = row.rstrip('\n').split('\t')
run('handoff-tsv-reader', ['/bin/bash', '-c', 'row="$(/bin/bash "$1" resolve build)"; IFS=$\'\t\' read -r -a fields <<< "$row"; printf "field_count=%s\\n" "${#fields[@]}"; printf "<%s>\\n" "${fields[@]}"', 'review-read', str(script)], 0)

# Same-model audit is calculated before the launcher applies an override.
doc = json.loads(saved_config)
config.write_text(json.dumps(doc))
row = seats('resolve-pre-override', 'resolve', 'build', expected=0).stdout.rstrip('\n').split('\t')
results['override_conflict_gap'] = {'configured_build': row[4], 'gate_model': doc['seats']['gate']['occupant']['model'], 'configured_conflict': row[8], 'override_to_gate_model_would_match': True}

# Migration and reset share a path even though reset promises bundle defaults.
old = json.loads(legacy.read_text())
profile = old['profiles'][old['default_profile']]
profile['planning_model'] = 'custom-planner'
profile['reasoning_effort'] = 'high'
legacy.write_text(json.dumps(old))
config.unlink()
seats('suggest-custom-legacy', 'suggest', expected=0)
seats('wizard-custom-legacy', 'wizard', '--yes', expected=0)
results['migrated_gate'] = json.loads(config.read_text())['seats']['gate']['occupant']
seats('reset-with-legacy', 'reset', expected=0)
results['reset_gate'] = json.loads(config.read_text())['seats']['gate']['occupant']

# A valid legacy effort which the conservative new catalog excludes.
profile['reasoning_effort'] = 'low'
legacy.write_text(json.dumps(old))
config.unlink()
seats('wizard-valid-legacy-low', 'wizard', '--yes')
seats('reset-invalid-migration', 'reset')
seats('validate-after-reset', 'validate')
legacy.unlink()
seats('reset-without-legacy', 'reset', expected=0)

# Catalog is authoritative; a stale malformed migration file should not gate it.
good_config = config.read_bytes()
legacy.write_text('{broken')
seats('wizard-valid-seats-broken-legacy', 'wizard', '--yes')
legacy.unlink()
config.write_bytes(good_config)

# Render must preserve unrelated AGENTS bytes, including USER block newlines.
agents.write_bytes(b'# Project\r\n\r\n<!-- BEGIN USER: notes -->\r\nkeep me\r\n<!-- END USER: notes -->\r\n')
old_agents = agents.read_bytes()
seats('render-crlf', 'render', expected=0)
results['render_preserves_original_prefix_bytes'] = agents.read_bytes().startswith(old_agents)

after = {name: digest(repo / name) for name in source_files}
summary = {'target': str(target), 'source_sha256': before, 'source_unchanged': before == after, 'results': results}
(out / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
print(json.dumps(summary, indent=2))
