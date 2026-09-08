#!/usr/bin/env python3
"""Additional independent v3 review probes; all writes are to temp targets."""
import copy
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

out = Path(__file__).resolve().parent
source = out.parent / 'reference-agent-seats.sh'
target = Path(tempfile.mkdtemp(prefix='seats-v3-edge-')).resolve()
(target / 'scripts').mkdir()
cfg = target / 'docs/agent-configs'
cfg.mkdir(parents=True)
script = target / 'scripts/agent-seats.sh'
shutil.copy2(source, script)
config = cfg / 'seats.json'
agents = target / 'AGENTS.md'
agents.write_text('# Probe\n')
env = {**os.environ, 'GIT_OPTIONAL_LOCKS': '0'}
results = {'target': str(target), 'uid': os.getuid()}


def record(name, r):
    (out / (name + '.stdout')).write_text(r.stdout)
    (out / (name + '.stderr')).write_text(r.stderr)
    results[name] = {'rc': r.returncode, 'traceback': 'Traceback' in r.stderr}
    return r


def run(name, *args):
    return record(name, subprocess.run(['/bin/bash', str(script), *args], cwd=target,
                                      env=env, capture_output=True, text=True, timeout=20))


assert run('v3-init', 'init').returncode == 0
baseline = json.loads(config.read_text())
for shape in ('not-an-object', [], True):
    doc = copy.deepcopy(baseline)
    doc['catalog']['models']['gpt-6-astra'] = shape
    config.write_text(json.dumps(doc))
    name = 'model-shape-' + type(shape).__name__
    run(name, 'validate')

# init must not overwrite anything that appeared while it waited for a writer.
for case, payload in [('malformed', b'{ malformed'), ('invalid', b'{"schema":"wrong"}')]:
    config.unlink(missing_ok=True)
    fd = os.open(cfg, os.O_RDONLY)
    fcntl.flock(fd, fcntl.LOCK_EX)
    proc = subprocess.Popen(['/bin/bash', str(script), 'init'], cwd=target, env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    time.sleep(0.6)
    was_waiting = proc.poll() is None
    config.write_bytes(payload)
    fcntl.flock(fd, fcntl.LOCK_UN)
    os.close(fd)
    stdout, stderr = proc.communicate(timeout=15)
    r = subprocess.CompletedProcess(proc.args, proc.returncode, stdout, stderr)
    name = 'init-after-lock-' + case
    record(name, r)
    results[name].update(waiting_before_publish=was_waiting,
                         published_bytes_preserved=config.read_bytes() == payload)

# Exercise RLIMIT_FSIZE after the shell has loaded the embedded Python program.
# The unmodified harness sets it before Bash creates its heredoc temporary file.
raw = source.read_text()
program = raw.split("read -r -d '' SEATS_PY <<'PY' || true\n", 1)[1].split('\nPY\n', 1)[0]
pyenv = {**env, 'SEATS_FILE': str(config), 'LEGACY_PROFILES': str(cfg / 'model-profiles.json'),
         'AGENTS_MD': str(agents)}
for limit, expected_rc, expect_seats_change in [(4096, 2, True), (1024, 1, False)]:
    config.write_text(json.dumps(baseline, indent=2) + '\n')
    agents.write_text('# Probe\n' + 'FILLER\n' * 2000)
    before_config, before_agents = config.read_bytes(), agents.read_bytes()
    code = 'import resource\nresource.setrlimit(resource.RLIMIT_FSIZE, (' + str(limit) + ',' + str(limit) + '))\n' + program
    r = subprocess.run([sys.executable, '-c', code, 'set', 'build', '--effort', 'high'],
                       cwd=target, env=pyenv, capture_output=True, text=True, timeout=15)
    name = 'atomic-python-limit-' + str(limit)
    record(name, r)
    results[name].update(config_changed=config.read_bytes() != before_config,
                         agents_preserved=agents.read_bytes() == before_agents)
    results[name]['contract_pass'] = (r.returncode == expected_rc and
                                     results[name]['config_changed'] == expect_seats_change and
                                     results[name]['agents_preserved'] and not results[name]['traceback'])

(out / 'edge-summary.json').write_text(json.dumps(results, indent=2) + '\n')
print(json.dumps(results, indent=2))
