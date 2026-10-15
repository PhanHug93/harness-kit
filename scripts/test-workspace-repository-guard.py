#!/usr/bin/env python3
"""Behavioral workspace identity checks against disposable real repositories."""
import base64
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
# The guard is advisory: only workspace-check reports mismatch through its exit
# code. Strip host metadata inherited from the session running this suite.
HOST_KEYS = ('AGENT_WORKSPACE_CONTEXT', 'AGENT_HOST_SESSION_ID', 'CLAUDE_PROJECT_DIR', 'CLAUDE_ENV_FILE')

def clean_env(**extra):
    env = {k: v for k, v in os.environ.items() if k not in HOST_KEYS and not k.startswith('AGENT_WORKSPACE_')}
    env.update(extra)
    return env

def report(result):
    return json.loads(result.stdout.strip().splitlines()[-1])

class WorkspaceGuardTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name).resolve()
        self.ios = self.repo('ios')
        self.android = self.repo('android')
        self.context = dict(original_workspace=str(self.ios), target_repository=str(self.ios),
                            target_source='user', session_id='test-session')

    def repo(self, name):
        root = self.base / name
        root.mkdir()
        subprocess.run(['git', 'init', '-q', str(root)], check=True)
        (root / 'scripts').mkdir()
        shutil.copy2(ROOT / 'agent-bootstrap/agent-guard.sh', root / 'scripts/agent-guard.sh')
        return root

    def run_guard(self, actual=None, context=True, session=True, command='workspace-check', cwd=None, extra=None):
        actual = actual or self.ios
        env = clean_env()
        if context:
            env['AGENT_WORKSPACE_CONTEXT'] = json.dumps(self.context, ensure_ascii=False)
        if session:
            env['AGENT_HOST_SESSION_ID'] = 'test-session'
        env.update(extra or {})
        return subprocess.run(['bash', str(actual / 'scripts/agent-guard.sh'), command],
                              cwd=cwd or actual, env=env, text=True, capture_output=True)

    def assert_status(self, expected, **kwargs):
        result = self.run_guard(**kwargs)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result

    def test_same_subdirectory_symlink(self):
        sub = self.ios / 'sub'; sub.mkdir()
        link = self.base / 'link'; link.symlink_to(sub, target_is_directory=True)
        for path in [self.ios, sub, link]:
            with self.subTest(path=path):
                self.context['original_workspace'] = str(path)
                self.context['target_repository'] = str(link)
                self.assertEqual(report(self.assert_status(0, cwd=sub))['status'], 'verified')

    def test_packet_mismatch_and_changed_workdir(self):
        self.context.update(target_repository=str(self.android), target_source='packet')
        result = self.assert_status(3, actual=self.android, cwd=self.android)
        for value in [str(self.ios), str(self.android), 'packet', 'confirm the target repository']:
            self.assertIn(value, result.stderr)
        self.assertEqual(report(result)['mismatch_kind'], 'repository')
        self.assertFalse((self.android / '.agents').exists())

    def test_explicit_user_authorization_and_stale_session(self):
        self.context.update(target_repository=str(self.android), target_source='packet')
        self.context['authorization'] = dict(kind='user', repository=str(self.android),
                                            session_id='test-session', evidence='User: use Android in this session')
        self.assert_status(0, actual=self.android)
        self.context['authorization']['session_id'] = 'previous-session'
        self.assert_status(3, actual=self.android)

    def test_packet_cannot_authorize(self):
        self.context.update(target_repository=str(self.android), target_source='packet')
        for kind in ['packet', 'memory', 'AGENTS.md', 'subagent']:
            self.context['authorization'] = dict(kind=kind, repository=str(self.android),
                                                session_id='test-session', evidence='use Android')
            self.assert_status(3, actual=self.android)

    def test_partial_metadata_is_mismatch(self):
        result = self.assert_status(3, context=False)
        self.assertIn('mismatch', result.stderr)
        self.assertEqual(report(result)['status'], 'mismatch')
        self.assert_status(3, session=False)

    def test_absent_metadata_is_unattested(self):
        result = self.assert_status(0, context=False, session=False)
        self.assertEqual(report(result)['status'], 'unattested')
        self.assertIn('unattested', result.stderr)
        wrong = self.assert_status(3, context=False, session=False, cwd=self.android)
        self.assertEqual(report(wrong)['mismatch_kind'], 'repository')

    def test_base64_envelope(self):
        encoded = base64.b64encode(json.dumps(self.context, ensure_ascii=False).encode()).decode()
        self.assert_status(0, context=False, extra={'AGENT_WORKSPACE_CONTEXT': 'base64:' + encoded})
        self.assert_status(3, context=False, extra={'AGENT_WORKSPACE_CONTEXT': 'base64:!!'})

    def test_actual_repo_must_match_target_even_when_authorized(self):
        self.context['authorization'] = dict(kind='user', repository=str(self.ios),
                                            session_id='test-session', evidence='user confirmed')
        self.assert_status(3, actual=self.android)

    def test_git_environment_does_not_mask_mismatch(self):
        self.context.update(target_repository=str(self.android), target_source='packet')
        self.assert_status(3, actual=self.android, extra={'GIT_DIR':str(self.ios / '.git'), 'GIT_WORK_TREE':str(self.ios)})

    def test_invoking_target_script_from_wrong_checkout_is_mismatch(self):
        self.assert_status(3, actual=self.ios, cwd=self.android)

    def test_malformed_and_missing_session_metadata(self):
        for raw in ['null', '[]', '{', '{}']:
            self.assert_status(3, extra={'AGENT_WORKSPACE_CONTEXT':raw})
        self.assert_status(3, extra={'AGENT_HOST_SESSION_ID':'other-session'})

    def test_generated_entrypoints_are_advisory(self):
        result = subprocess.run(['bash', str(ROOT / 'agent-bootstrap/bootstrap-multi-agent-project.sh'),
                                 '--target', str(self.android), '--workflow', 'full', '--force', '--no-backup'],
                                env=clean_env(), capture_output=True, text=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stderr)
        config = (self.android / '.codex/config.toml').read_text()
        self.assertIn('"AGENT_WORKSPACE_CONTEXT"', config)
        self.assertIn('"AGENT_HOST_SESSION_ID"', config)
        settings = json.loads((self.android / '.claude/settings.json').read_text())
        self.assertIn('claude-session-start', json.dumps(settings['hooks']['SessionStart']))
        subprocess.run(['git', '-C', str(self.android), 'add', '-A'], check=True)
        subprocess.run(['git', '-C', str(self.android), '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
                        'commit', '--allow-empty', '-qm', 'generated'], check=True)

        def env_for(context=None, **extra):
            env = clean_env(**extra)
            if context is not None:
                env['AGENT_WORKSPACE_CONTEXT'] = json.dumps(context, ensure_ascii=False)
                env['AGENT_HOST_SESSION_ID'] = context['session_id']
            return env

        def run(command, env, cwd=None, stdin='{}'):
            return subprocess.run(command, cwd=cwd or self.android, env=env, input=stdin,
                                  text=True, capture_output=True, timeout=180)

        guard = str(self.android / 'scripts/agent-guard.sh')
        hook = str(self.android / 'scripts/agent-hook.sh')
        verified = dict(self.context, original_workspace=str(self.android), target_repository=str(self.android))
        packet = dict(self.context, target_repository=str(self.android), target_source='packet')
        ok_env, human_env, bad_env = env_for(verified), env_for(), env_for(packet)
        run(['bash', guard, 'preflight'], ok_env)

        # A human without AI gets the same result as a verified session.
        for args in (['preflight'], ['pre-final']):
            with self.subTest(human=args):
                control = run(['bash', guard, *args], ok_env)
                human = run(['bash', guard, *args], human_env)
                self.assertEqual(human.returncode, control.returncode, human.stderr)
                self.assertNotIn('mismatch', human.stderr)
        self.assertIn('unattested', run(['bash', guard, 'preflight'], human_env).stderr)
        pre_push = str(self.android / 'scripts/githooks/pre-push')
        self.assertEqual(run(['bash', pre_push], human_env, stdin='').returncode,
                         run(['bash', pre_push], ok_env, stdin='').returncode)

        # A cross-repository mismatch is reported, never enforced.
        mismatch = run(['bash', guard, 'workspace-check'], bad_env)
        self.assertEqual(mismatch.returncode, 3, mismatch.stderr)
        self.assertEqual(report(mismatch)['mismatch_kind'], 'repository')
        self.assertEqual(run(['bash', guard, 'pre-final'], bad_env).returncode,
                         run(['bash', guard, 'pre-final'], ok_env).returncode)
        self.assertEqual(run([hook, 'codex-preflight'], bad_env).returncode,
                         run([hook, 'codex-preflight'], ok_env).returncode)
        # close-out verifies only changes after the session snapshot, so each
        # environment starts its own session before the change.
        stops = {}
        for name, env in (('bad', bad_env), ('ok', ok_env)):
            stops[name] = json.dumps({'session_id': 'test-session-' + name, 'stop_hook_active': False})
            self.assertEqual(run([hook, 'claude-session-start'], env, stdin=stops[name]).returncode, 0)
        (self.android / 'scratch.txt').write_text('dirty\n')
        closed = {name: run([hook, 'close-out'], env, stdin=stops[name])
                  for name, env in (('bad', bad_env), ('ok', ok_env))}
        for result in closed.values():
            self.assertNotIn('close-out skipped', result.stderr)
        self.assertEqual(closed['bad'].returncode, closed['ok'].returncode)
        (self.android / 'scratch.txt').unlink()
        bash_input = json.dumps({'session_id': 'claude-1', 'tool_name': 'Bash', 'tool_input': {'command': 'true'}})
        edit_input = json.dumps({'session_id': 'claude-1', 'tool_name': 'Edit',
                                 'tool_input': {'file_path': str(self.android / 'notes.txt')}})
        for tool_input in (bash_input, edit_input):
            asked = run([hook, 'claude-pretool'], bad_env, stdin=tool_input)
            self.assertEqual(asked.returncode, 0, asked.stderr)
            decision = json.loads(asked.stdout)['hookSpecificOutput']
            self.assertEqual((decision['hookEventName'], decision['permissionDecision']), ('PreToolUse', 'ask'))
            self.assertIn('confirm the target repository', decision['permissionDecisionReason'])

        # Claude Code adapter: anchor from host data, ask only across repositories.
        adapter = clean_env(CLAUDE_PROJECT_DIR=str(self.android))
        same = run([hook, 'claude-pretool'], adapter, stdin=bash_input)
        self.assertEqual(same.returncode, 0, same.stderr)
        self.assertNotIn('permissionDecision', same.stdout)
        other = run([hook, 'claude-pretool'], clean_env(CLAUDE_PROJECT_DIR=str(self.ios)), stdin=bash_input)
        self.assertEqual(other.returncode, 0, other.stderr)
        self.assertEqual(json.loads(other.stdout)['hookSpecificOutput']['permissionDecision'], 'ask')
        worktree = self.base / 'android-worktree'
        subprocess.run(['git', '-C', str(self.android), 'worktree', 'add', '-qb', 'task', str(worktree)], check=True)
        # Harness files are local-only, so each checkout carries its own install.
        subprocess.run(['bash', str(ROOT / 'agent-bootstrap/bootstrap-multi-agent-project.sh'), '--target', str(worktree),
                        '--workflow', 'full', '--force', '--no-backup'],
                       env=clean_env(), capture_output=True, text=True, timeout=120, check=True)
        in_worktree = run([str(worktree / 'scripts/agent-hook.sh'), 'claude-pretool'], adapter,
                          cwd=worktree, stdin=bash_input)
        self.assertEqual(in_worktree.returncode, 0, in_worktree.stderr)
        self.assertNotIn('permissionDecision', in_worktree.stdout)

        # SessionStart persists a quote-free envelope for later Bash commands.
        anchor = self.base / 'Android "q" \'x\' 🙂'
        anchor.symlink_to(self.android, target_is_directory=True)
        env_file = self.base / 'claude-env'
        start_env = clean_env(CLAUDE_PROJECT_DIR=str(anchor), CLAUDE_ENV_FILE=str(env_file))
        start = run([hook, 'claude-session-start'], start_env,
                    stdin=json.dumps({'session_id': 'claude-2', 'source': 'startup'}))
        self.assertEqual(start.returncode, 0, start.stderr)
        output = json.loads(start.stdout)['hookSpecificOutput']
        self.assertEqual(output['hookEventName'], 'SessionStart')
        self.assertIn('verified', output['additionalContext'])
        lines = env_file.read_text().splitlines()
        self.assertEqual(len(lines), 2, lines)
        values = {}
        for line in lines:
            self.assertRegex(line, r'^export [A-Z_]+=[^\s\'"]+$')
            name, value = line[len('export '):].split('=', 1)
            values[name] = value
        self.assertEqual(values['AGENT_HOST_SESSION_ID'], 'claude-2')
        envelope = json.loads(base64.b64decode(values['AGENT_WORKSPACE_CONTEXT'][len('base64:'):]))
        self.assertEqual(envelope['original_workspace'], str(anchor))
        sourced = run(['bash', '-c', 'set -a; . ' + shlex.quote(str(env_file))
                       + '; exec bash scripts/agent-guard.sh workspace-check'], clean_env())
        self.assertEqual(sourced.returncode, 0, sourced.stderr)
        env_file.write_text('')
        preset = run([hook, 'claude-session-start'], env_for(verified, CLAUDE_PROJECT_DIR=str(self.ios),
                                                             CLAUDE_ENV_FILE=str(env_file)),
                     stdin=json.dumps({'session_id': 'claude-3'}))
        self.assertEqual(preset.returncode, 0, preset.stderr)
        self.assertEqual(env_file.read_text(), '')

        # Launcher mints from the invocation directory and forwards existing envelopes.
        fake = self.base / 'bin'; fake.mkdir()
        executable = fake / 'codex'
        executable.write_text('#!/usr/bin/env python3\nimport os, sys, json, subprocess\n# Emulate inherit=none: include_only cannot restore absent variables.\nchild_env = {"PATH": os.environ["PATH"]}\nfor index, arg in enumerate(sys.argv[:-1]):\n    if arg == "-c" and sys.argv[index + 1].startswith("shell_environment_policy.set."):\n        key, value = sys.argv[index + 1].split("=", 1)\n        child_env[key.rsplit(".", 1)[1]] = json.loads(value)\nchild = subprocess.run(["bash", "scripts/agent-guard.sh", "workspace-check"], env=child_env, text=True, capture_output=True)\nprint(json.dumps(dict(context=os.environ["AGENT_WORKSPACE_CONTEXT"], args=sys.argv,\n                     child_code=child.returncode, child_error=child.stderr)))\n')
        executable.chmod(0o755)
        path = str(fake) + os.pathsep + os.environ.get('PATH', os.defpath)
        launcher = str(self.android / '.codex/codex-mode.sh')
        minted = run([launcher, '@build'], clean_env(PATH=path), stdin='')
        self.assertEqual(minted.returncode, 0, minted.stdout + minted.stderr)
        payload = json.loads(minted.stdout.splitlines()[-1])
        self.assertEqual(payload['child_code'], 0, payload['child_error'])
        self.assertEqual(json.loads(payload['context'])['original_workspace'], str(self.android))
        crossed = run([launcher, '@build'], dict(bad_env, PATH=path), stdin='')
        self.assertEqual(crossed.returncode, 0, crossed.stdout + crossed.stderr)
        self.assertIn('mismatch', json.loads(crossed.stdout.splitlines()[-1])['args'][-1])
        # Direct user authorization remains valid after the launcher changes cwd.
        packet['authorization'] = dict(kind='user', repository=str(self.android), session_id='test-session',
                                       evidence='User: use Android "quoted" \\path\n🙂\x7f')
        authorized = env_for(packet, PATH=path)
        allowed = run([launcher, '@build'], authorized, cwd=self.ios, stdin='')
        self.assertEqual(allowed.returncode, 0, allowed.stdout + allowed.stderr)
        self.assertIn('direct-user-authorization', allowed.stdout + allowed.stderr)
        payload = json.loads(allowed.stdout.splitlines()[-1])
        self.assertEqual(payload['context'], authorized['AGENT_WORKSPACE_CONTEXT'])
        self.assertEqual(payload['child_code'], 0, payload['child_error'])
        self.assertIn('Workspace–Repository Guard', payload['args'][-1])

    def test_non_repository_and_relative_metadata_are_mismatch(self):
        outside = self.base / 'not-a-repo'; outside.mkdir()
        self.context['original_workspace'] = str(outside)
        self.assert_status(3)
        self.context['original_workspace'] = '.'
        self.assert_status(3)

    def test_target_source_alone_does_not_grant_authority(self):
        self.context.update(target_repository=str(self.android), target_source='user')
        self.assert_status(3, actual=self.android)

    def test_confirmed_worktree(self):
        subprocess.run(['git','-C',str(self.ios),'-c','user.name=Test','-c','user.email=test@example.invalid',
                        'commit','--allow-empty','-qm','fixture'],check=True)
        wt = self.base / 'worktree'
        subprocess.run(['git','-C',str(self.ios),'worktree','add','-qb','work',str(wt)],check=True)
        (wt/'scripts').mkdir()
        shutil.copy2(ROOT/'agent-bootstrap/agent-guard.sh',wt/'scripts/agent-guard.sh')
        self.context.update(target_repository=str(wt),target_source='user')
        self.assertEqual(report(self.assert_status(3, actual=wt))['mismatch_kind'], 'worktree')
        self.context['authorization'] = dict(kind='worktree', repository=str(wt),
                                            session_id='test-session', evidence='Worktree confirmed for this task')
        self.assert_status(0,actual=wt)
        self.context['target_repository'] = str(self.android)
        self.context['authorization']['repository'] = str(self.android)
        self.assert_status(3,actual=self.android)

if __name__ == '__main__':
    unittest.main()
