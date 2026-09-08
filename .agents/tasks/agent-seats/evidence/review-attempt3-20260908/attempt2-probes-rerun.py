#!/usr/bin/env python3
"""Attempt 2 edge probes; only disposable targets are changed."""
import copy
import json
import os
from pathlib import Path
import pty
import select
import shutil
import subprocess
import tempfile
import time

out = Path(__file__).resolve().parent
evidence = out.parent
root = evidence.parents[3]
target = Path(tempfile.mkdtemp(prefix='seats-v2-edge-')).resolve()
(target / 'scripts').mkdir()
(target / 'docs/agent-configs').mkdir(parents=True)
script = target / 'scripts/agent-seats.sh'
shutil.copy2(evidence / 'reference-agent-seats.sh', script)
config = target / 'docs/agent-configs/seats.json'
agents = target / 'AGENTS.md'
legacy = target / 'docs/agent-configs/model-profiles.json'
agents.write_bytes(b'# Probe\n\nUSER_PREFIX\n')
env = {**os.environ, 'GIT_OPTIONAL_LOCKS': '0'}
results = {'target': str(target), 'uid': os.getuid()}


def run(name, *args):
    r = subprocess.run(['/bin/bash', str(script), *args], env=env, cwd=target,
                       capture_output=True, text=True, timeout=15)
    (out / (name + '.stdout')).write_text(r.stdout)
    (out / (name + '.stderr')).write_text(r.stderr)
    results[name] = {'rc': r.returncode, 'args': args, 'stdout_lines': len(r.stdout.splitlines())}
    return r


assert run('edge-init-defaults', 'init').returncode == 0
baseline = json.loads(config.read_text())


def write(doc):
    config.write_text(json.dumps(doc, indent=4) + '\n\n')


def terminal(name, answers):
    write(baseline)
    before = config.read_bytes()
    master, slave = pty.openpty()
    proc = subprocess.Popen(['/bin/bash', str(script), 'wizard'], cwd=target,
                            env=env, stdin=slave, stdout=slave, stderr=slave)
    os.close(slave)
    transcript = b''
    pending = b''
    count = 0
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        ready, _, _ = select.select([master], [], [], 0.1)
        if ready:
            try:
                chunk = os.read(master, 65536)
            except OSError:
                break
            if not chunk:
                break
            transcript += chunk
            pending += chunk
            if pending.rstrip().endswith(b'>'):
                answer = answers[count] if count < len(answers) else ''
                count += 1
                os.write(master, (answer + '\n').encode())
                pending = b''
        elif proc.poll() is not None:
            break
    try:
        rc = proc.wait(timeout=1)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
        rc = -1
    os.close(master)
    (out / (name + '.pty')).write_bytes(transcript)
    results[name] = {'rc': rc, 'prompts': count,
                     'config_unchanged': config.read_bytes() == before}


# Syntactically invalid choices must not be silently accepted.
terminal('invalid-host-number', ['99'])
terminal('invalid-model-number', ['', '', '99'])
terminal('invalid-fallback-number', ['', '', '', '', '99'])

# Python $ accepts a final newline; match() is not fullmatch().
doc = copy.deepcopy(baseline)
doc['catalog']['models']['custom\n'] = {'host': 'codex', 'efforts': ['high'], 'default_effort': 'high'}
doc['seats']['gate']['occupant']['model'] = 'custom\n'
doc['seats']['gate']['occupant']['effort'] = 'high'
write(doc)
run('newline-model-validate', 'validate')
run('newline-model-resolve', 'resolve', 'gate')

doc = copy.deepcopy(baseline)
doc['catalog']['models']['gpt-6-astra']['efforts'].append('high\n')
doc['seats']['gate']['occupant']['effort'] = 'high\n'
write(doc)
run('newline-effort-validate', 'validate')
run('newline-effort-resolve', 'resolve', 'gate')

# resolve emits optional metadata too, including on host-controlled seats.
doc = copy.deepcopy(baseline)
doc['seats']['gate']['occupant'] = {'host': 'claude', 'model': 'informational\nmodel'}
write(doc)
run('noncodex-newline-validate', 'validate')
run('noncodex-newline-resolve', 'resolve', 'gate')

doc = copy.deepcopy(baseline)
doc['seats']['gate']['occupant'].pop('fallback_model')
doc['seats']['gate']['occupant']['fallback_effort'] = 'high\nxhigh'
write(doc)
run('orphan-fallback-effort-validate', 'validate')
run('orphan-fallback-effort-resolve', 'resolve', 'gate')

# A real write error after saving the configuration must use partial-success rc 2.
write(baseline)
run('render-before-permission-probe', 'render')
before = config.read_bytes()
agents_before = agents.read_bytes()
agents.chmod(0o444)
try:
    run('readonly-roster-set', 'set', 'build', '--effort', 'high')
finally:
    agents.chmod(0o644)
results['readonly-roster-set'].update(config_changed=config.read_bytes() != before,
                                     agents_unchanged=agents.read_bytes() == agents_before)

# Parsed JSON can still violate the legacy schema's required route fields.
config.unlink()
legacy.write_text(json.dumps({'schema': 'agent-model-profiles/v1', 'default_profile': 'stable',
                             'profiles': {'stable': {'reasoning_effort': 'high'}}}))
run('incomplete-legacy-init', 'init')
results['incomplete-legacy-init']['config_created'] = config.exists()

# Fresh current generator creates legacy defaults, which an end-of-run init sees.
generated = Path(tempfile.mkdtemp(prefix='seats-v2-generation-')).resolve()
subprocess.run(['git', 'init', '-q'], cwd=generated, env=env, check=True)
p = subprocess.run(['/bin/bash', str(root / 'scripts/bootstrap-multi-agent-project.sh'),
                    '--target', str(generated), '--workflow', 'full'], env=env,
                   capture_output=True, text=True, timeout=60)
(out / 'generation.stdout').write_text(p.stdout)
(out / 'generation.stderr').write_text(p.stderr)
assert p.returncode == 0
gscript = generated / 'scripts/agent-seats.sh'
shutil.copy2(script, gscript)
p = subprocess.run(['/bin/bash', str(gscript), 'roster-block'], env=env,
                   capture_output=True, text=True, timeout=10)
(out / 'roster-before-init.stderr').write_text(p.stderr)
results['roster-before-init'] = {'rc': p.returncode}
p = subprocess.run(['/bin/bash', str(gscript), 'init'], env=env,
                   capture_output=True, text=True, timeout=10)
(out / 'generation-init.stdout').write_text(p.stdout)
(out / 'generation-init.stderr').write_text(p.stderr)
gdoc = json.loads((generated / 'docs/agent-configs/seats.json').read_text())
results['end-of-fresh-generation-init'] = {
    'rc': p.returncode, 'generated_target': str(generated),
    'gate': gdoc['seats']['gate']['occupant'],
    'legacy_created_by_generator': (generated / 'docs/agent-configs/model-profiles.json').exists(),
    'note': 'Probe of the proposed ordering using current generator and unchanged v2 reference, not an integrated seats implementation.'}

(out / 'independent-summary.json').write_text(json.dumps(results, indent=2) + '\n')
print(json.dumps(results, indent=2))
