"""Exercise the built CLI against isolated local fixtures; no network or installs."""
import ast
import contextlib
import io
import json
import re
import textwrap
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

BINARY = Path(sys.argv.pop(1)).resolve() if len(sys.argv) > 1 else Path('.build/debug/repoman').resolve()


class CLITests(unittest.TestCase):
    def test_secret_annotation_protocol_escapes_properties_and_omits_source(self):
        workflow = (Path(__file__).resolve().parents[1] / '.github/workflows/secret-scanning.yml').read_text()
        script = textwrap.dedent(workflow.split("python3 - <<'PY'\n", 1)[1].rsplit('          PY', 1)[0])
        parsed = ast.parse(script)  # Also validate the complete embedded script syntax.
        functions = [node for node in parsed.body if isinstance(node, ast.FunctionDef)
                     and node.name in {'property_value', 'annotation'}]
        self.assertEqual(len(functions), 2)
        namespace = {'re': re}
        exec(compile(ast.Module(body=functions, type_ignores=[]), '<annotation-protocol>', 'exec'), namespace)
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            namespace['annotation']('src/100%,config.py', 12, 'api-key')
            for path in ('../private', '/private', 'src/\nconfig.py', 'src/./config.py'):
                namespace['annotation'](path, 1, 'api-key')
            namespace['annotation']('src/config.py', 0, 'api-key')
            namespace['annotation']('src/config.py', 1, 'untrusted title\n::error::injected')
        self.assertEqual(output.getvalue(), '::error file=src/100%25%2Cconfig.py,line=12,title=RepoMan secret scan%3A api-key::Potential credential pattern; matched content withheld.\n')

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name) / "repo with 'quotes'"
        self.repo.mkdir()
        self.env = dict(os.environ, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull,
                        GIT_AUTHOR_NAME='Fixture', GIT_AUTHOR_EMAIL='fixture@example.invalid',
                        GIT_COMMITTER_NAME='Fixture', GIT_COMMITTER_EMAIL='fixture@example.invalid')
        self.git('init', '-b', 'main')
        self.git('config', 'commit.gpgsign', 'false')
        self.git('config', 'core.hooksPath', '/dev/null')
        (self.repo / 'README.md').write_text('Fixture\n')
        self.git('add', 'README.md')
        self.git('commit', '-m', 'Fixture')

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.repo), *args], env=self.env, stderr=subprocess.DEVNULL)

    def cli(self, *args):
        return subprocess.run([str(BINARY), *args], env=self.env, capture_output=True, text=True, timeout=30)

    def check(self, *args):
        return self.cli('check', '--repo', str(self.repo), '--format', 'json', *args)

    def test_vulnerabilities_require_remote_opt_in_but_no_comparison_base(self):
        self.assertIn('dependencies.vulnerabilities [remote]', self.cli('--list-checks').stdout)
        denied = self.check('--check', 'dependencies.vulnerabilities')
        self.assertEqual(denied.returncode, 2)
        self.assertIn('--remote', denied.stderr)
        local = self.check()
        payload = json.loads(local.stdout)
        entry = next(x for x in payload['checks'] if x['id'] == 'dependencies.vulnerabilities')
        self.assertEqual(entry['status'], 'skipped')
        self.assertNotIn('dependencyVulnerabilities', payload)

    def test_vulnerabilities_missing_lock_is_incomplete_without_network_or_base(self):
        (self.repo / 'package.json').write_text('{"name":"fixture","dependencies":{"child":"1.0.0"}}')
        result = self.check('--remote', '--check', 'dependencies.vulnerabilities')
        self.assertEqual(result.returncode, 3, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload['schemaVersion'], 3)
        self.assertEqual(payload['checks'][0]['status'], 'incomplete')
        evidence = payload['dependencyVulnerabilities']
        self.assertEqual(evidence['provider'], 'OSV')
        self.assertEqual(evidence['candidateHead'], self.git('rev-parse', 'HEAD').decode().strip())
        self.assertTrue(evidence['includesWorkingTree'])
        self.assertTrue(evidence['incompleteReasons'])
        self.assertEqual(evidence['versions'], [])
        self.assertEqual([x['path'] for x in evidence['inputs']], ['package.json'])
        self.assertEqual(len(evidence['inputs'][0]['sha256']), 64)
        self.assertNotIn('dependencyComparison', payload)
        self.assertFalse((self.repo / '.git/FETCH_HEAD').exists())

    def test_vulnerabilities_complete_empty_lock_has_bound_clear_evidence(self):
        (self.repo / 'package.json').write_text('{"name":"fixture"}')
        (self.repo / 'package-lock.json').write_text('{"lockfileVersion":3,"packages":{}}')
        result = self.check('--remote', '--check', 'dependencies.vulnerabilities')
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload['checks'][0]['status'], 'passed')
        evidence = payload['dependencyVulnerabilities']
        self.assertEqual(evidence['versions'], [])
        self.assertEqual(evidence['incompleteReasons'], [])
        self.assertEqual({x['path'] for x in evidence['inputs']}, {'package.json', 'package-lock.json'})
        self.assertTrue(all(x['side'] == 'candidate' for x in evidence['inputs']))

    def test_release_age_registration_and_explicit_base_requirement(self):
        listed = self.cli('--list-checks')
        self.assertIn('dependencies.releaseAge [remote]', listed.stdout)
        result = self.check('--check', 'dependencies.releaseAge', '--remote')
        self.assertEqual(result.returncode, 2)
        self.assertIn('--base', result.stderr)

    def test_release_age_rejects_missing_remote_duplicate_or_unused_base(self):
        for arguments in [('--check', 'dependencies.releaseAge', '--base', 'HEAD'),
                          ('--check', 'files.readme', '--remote', '--base', 'HEAD'),
                          ('--check', 'dependencies.releaseAge', '--remote', '--base', 'HEAD', '--base', 'HEAD'),
                          ('--check', 'dependencies.releaseAge', '--remote', '--base', 'not-an-existing-ref')]:
            with self.subTest(arguments=arguments):
                self.assertEqual(self.check(*arguments).returncode, 2)

    def test_release_age_is_explicitly_skipped_in_a_default_remote_run(self):
        result = self.check('--remote')
        self.assertIn(result.returncode, (0, 1, 3))
        payload = json.loads(result.stdout)
        check = next(x for x in payload['checks'] if x['id'] == 'dependencies.releaseAge')
        self.assertEqual(check['status'], 'skipped')
        self.assertIn('--base', check['reason'])
        self.assertNotIn('dependencyComparison', payload)

    def test_release_age_empty_external_inventory_records_base_and_hashes_without_writes(self):
        (self.repo / 'package.json').write_text('{"name":"fixture","version":"1.0.0","packageManager":"npm@11.20.0"}')
        (self.repo / 'package-lock.json').write_text('{"lockfileVersion":3,"packages":{"":{"name":"fixture","version":"1.0.0"}}}')
        self.git('add', '.'); self.git('commit', '-m', 'Empty external graph')
        base = self.git('rev-parse', 'HEAD').decode().strip()
        files = [self.repo / '.git' / name for name in ('index', 'HEAD', 'config')]
        before = [p.read_bytes() for p in files]
        result = self.check('--remote', '--check', 'dependencies.releaseAge', '--base', base)
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout); evidence = payload['dependencyComparison']
        self.assertEqual(evidence['baseCommit'], base)
        self.assertEqual(evidence['candidateHead'], base)
        self.assertTrue(evidence['includesWorkingTree'])
        self.assertEqual(evidence['minimumAgeDays'], 7)
        self.assertEqual(evidence['introduced'], [])
        self.assertEqual({x['side'] for x in evidence['inputs']}, {'base', 'candidate'})
        self.assertTrue(all(len(x['sha256']) == 64 for x in evidence['inputs']))
        self.assertEqual(before, [p.read_bytes() for p in files])

    def test_release_age_malformed_candidate_lock_is_incomplete_not_clear(self):
        (self.repo / 'package.json').write_text('{"name":"fixture"}')
        (self.repo / 'package-lock.json').write_text('{"lockfileVersion":3}')
        result = self.check('--remote', '--check', 'dependencies.releaseAge', '--base', 'HEAD')
        self.assertEqual(result.returncode, 3, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload['checks'][0]['status'], 'incomplete')
        self.assertTrue(payload['dependencyComparison']['incompleteReasons'])

    def test_release_age_npm_pnpm_migration_includes_untracked_files_and_unstaged_deletion(self):
        (self.repo / 'package.json').write_text('{"name":"fixture","packageManager":"npm@11.20.0"}')
        (self.repo / 'package-lock.json').write_text(json.dumps({'lockfileVersion':3,'packages':{'':{'name':'fixture'},
            'node_modules/child':{'version':'1.0.0','resolved':'https://registry.npmjs.org/child/-/child-1.0.0.tgz'}}}))
        self.git('add', '.'); self.git('commit', '-m', 'Locked package')
        base = self.git('rev-parse', 'HEAD').decode().strip()
        (self.repo / 'package-lock.json').unlink()
        (self.repo / 'pnpm-lock.yaml').write_text("lockfileVersion: '9.0'\npackages:\n  child@1.0.0:\n    resolution: {integrity: sha512-fixture}\n")
        result = self.check('--remote', '--check', 'dependencies.releaseAge', '--base', base)
        self.assertEqual(result.returncode, 0, result.stderr)
        evidence = json.loads(result.stdout)['dependencyComparison']
        self.assertEqual(evidence['introduced'], [])
        self.assertEqual({(x['side'],x['path']) for x in evidence['inputs']},
                         {('base','package-lock.json'),('candidate','pnpm-lock.yaml'),('candidate','package.json')})

    def test_actions_policy_is_catalogued_as_remote_and_requires_opt_in(self):
        listed = self.cli('--list-checks')
        self.assertEqual(listed.returncode, 0, listed.stderr)
        self.assertIn('ci.allowedActions [remote]', listed.stdout)
        denied = self.check('--check', 'ci.allowedActions')
        self.assertEqual(denied.returncode, 2)
        local = self.check()
        self.assertIn(local.returncode, (0, 1, 3))
        result = next(check for check in json.loads(local.stdout)['checks'] if check['id'] == 'ci.allowedActions')
        self.assertEqual(result['status'], 'skipped')

    def test_clean_findings_and_fresh_repair(self):
        clean = self.check('--check', 'files.readme')
        self.assertEqual(clean.returncode, 0, clean.stderr)
        self.assertEqual(json.loads(clean.stdout)['checks'][0]['status'], 'passed')
        (self.repo / 'README.md').unlink()
        missing = self.check('--check', 'files.readme')
        self.assertEqual(missing.returncode, 1)
        self.assertTrue(json.loads(missing.stdout)['checks'][0]['findings'][0]['id'])
        (self.repo / 'README.md').write_text('Repaired\n')
        self.assertEqual(self.check('--check', 'files.readme').returncode, 0)

    def test_information_is_visible_without_failing_a_scan(self):
        linked = Path(self.temp.name) / 'linked'
        self.git('worktree', 'add', '--detach', str(linked), 'HEAD')
        (self.repo / 'README.md').write_text('Local work\n')
        result = self.check('--check', 'git.changes', '--check', 'git.worktrees')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report['schemaVersion'], 3)
        self.assertTrue(all(c['status'] == 'information' for c in report['checks']))
        self.assertTrue(all(c['findings'][0]['severity'] == 'information' for c in report['checks']))
        # Adding a genuine missing README still fails, even with information present.
        (self.repo / 'README.md').unlink()
        result = self.check('--check', 'git.worktrees', '--check', 'files.readme')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)

    def test_uv_dependency_groups_compare_includes_and_other_platform_requirements(self):
        project = """[project]
name = 'fixture'
[dependency-groups]
Test_Group = ["pytest>=9; sys_platform == 'linux'"]
dev = [{include-group = 'test-group'}, 'ruff>=0.15']
empty = []
"""
        lock = """version = 1
[[package]]
name = 'fixture'
source = {virtual = '.'}
[package.metadata.requires-dev]
test-group = [{name = 'pytest', specifier = '>=9', marker = "sys_platform=='linux'"}]
dev = [{name = 'pytest', specifier = '>=9', marker = "sys_platform=='linux'"}, {name = 'ruff', specifier = '>=0.15'}]
empty = []
"""
        (self.repo / 'pyproject.toml').write_text(project)
        (self.repo / 'uv.lock').write_text(lock)
        self.git('add', 'pyproject.toml', 'uv.lock')
        result = self.check('--check', 'dependencies.lockfileDrift')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)['checks'][0]['status'], 'passed')
        (self.repo / 'pyproject.toml').write_text(project.replace('pytest>=9', 'pytest>=10'))
        result = self.check('--check', 'dependencies.lockfileDrift')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        finding = json.loads(result.stdout)['checks'][0]['findings'][0]
        self.assertIn('dependency-groups.dev.pytest', finding['evidence'])
        self.assertNotIn('linux', finding['evidence'])
        (self.repo / 'pyproject.toml').write_text(project)
        self.assertEqual(self.check('--check', 'dependencies.lockfileDrift').returncode, 0)

    def test_errors_have_no_partial_json(self):
        for args in [(), ('check',), ('check', '--repo', str(self.repo), '--check', 'unknown'),
                     ('check', '--repo', str(self.repo), '--check', 'github.description'),
                     ('check', '--repo', str(self.repo), '--format', 'xml'),
                     ('check', '--repo', str(self.repo), '--repo', str(self.repo)),
                     ('check', '--repo', str(self.repo), '--fetch', '--fetch')]:
            result = self.cli(*args)
            self.assertEqual(result.returncode, 2, args)
            self.assertEqual(result.stdout, '')

    def test_dependabot_skill_command_observes_configuration_repair(self):
        manifest = {'name': 'fixture', 'version': '1.0.0', 'packageManager': 'npm@10.0.0'}
        (self.repo / 'package.json').write_text(json.dumps(manifest))
        (self.repo / 'package-lock.json').write_text(json.dumps({
            'name': 'fixture', 'version': '1.0.0', 'lockfileVersion': 3,
            'packages': {'': {'name': 'fixture', 'version': '1.0.0'}}}))
        self.git('add', 'package.json', 'package-lock.json')
        checks = ('--check', 'dependencies.safeguards', '--check', 'dependencies.lockfile',
                  '--check', 'dependencies.lockfileDrift')
        before = self.check(*checks)
        self.assertEqual(before.returncode, 1, before.stderr)
        self.assertTrue(next(c for c in json.loads(before.stdout)['checks']
                             if c['id'] == 'dependencies.safeguards')['findings'])
        (self.repo / '.npmrc').write_text('min-release-age=10080\nignore-scripts=true\n')
        after = self.check(*checks)
        self.assertEqual(after.returncode, 0, after.stdout + after.stderr)
        self.assertTrue(all(c['status'] == 'passed' for c in json.loads(after.stdout)['checks']))

    def test_offline_report_cannot_fetch_or_run_fsmonitor(self):
        self.git('remote', 'add', 'origin', 'https://github.com/fixture/private-fixture.git')
        monitor = self.repo / 'monitor.sh'
        marker = self.repo / 'monitor-ran'
        monitor.write_text('#!/bin/sh\ntouch "' + str(marker) + '"\n')
        monitor.chmod(0o700)
        self.git('config', 'core.fsmonitor', str(monitor))
        paths = [self.repo / '.git' / name for name in ['HEAD', 'index', 'config', 'logs/HEAD']]
        before = [p.read_bytes() for p in paths]
        report = self.check()
        self.assertEqual(report.returncode, 3, report.stderr)
        remote = [c for c in json.loads(report.stdout)['checks'] if c['id'] == 'github.description']
        self.assertEqual(remote[0]['status'], 'skipped')
        self.assertEqual([p.read_bytes() for p in paths], before)
        self.assertFalse(marker.exists())
        self.assertFalse((self.repo / '.git/FETCH_HEAD').exists())

    def test_incomplete_policy_and_unborn_checkout(self):
        (self.repo / '.repoman.json').write_text('invalid')
        result = self.check('--check', 'dependencies.safeguards')
        self.assertEqual(result.returncode, 3)
        self.assertEqual(json.loads(result.stdout)['checks'][0]['status'], 'incomplete')
        unborn = Path(self.temp.name) / 'unborn'
        unborn.mkdir()
        subprocess.check_call(['git', 'init', '-q', str(unborn)], env=self.env)
        result = self.cli('check', '--repo', str(unborn), '--check', 'files.readme', '--format', 'json')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIsNone(json.loads(result.stdout)['head'])

    def test_no_supported_manifests_is_explicitly_not_applicable(self):
        result = self.check('--check', 'dependencies.safeguards', '--check', 'dependencies.lockfile',
                            '--check', 'dependencies.lockfileDrift')
        self.assertEqual(result.returncode, 0, result.stderr)
        checks = json.loads(result.stdout)['checks']
        self.assertTrue(all(c['status'] == 'not_applicable' and c['reason'] for c in checks))
        text = self.cli('check', '--repo', str(self.repo), '--check', 'dependencies.safeguards')
        self.assertIn('not_applicable', text.stdout)

    def test_unfetched_local_counts_are_provisional_even_when_aligned(self):
        self.git('remote', 'add', 'origin', str(Path(self.temp.name) / 'unreachable'))
        self.git('update-ref', 'refs/remotes/origin/main', 'HEAD')
        self.git('config', 'branch.main.remote', 'origin')
        self.git('config', 'branch.main.merge', 'refs/heads/main')
        aligned = self.check('--check', 'git.push')
        self.assertEqual(aligned.returncode, 3)
        self.assertEqual(json.loads(aligned.stdout)['checks'][0]['status'], 'incomplete')
        self.git('commit', '--allow-empty', '-m', 'Local work')
        ahead = self.check('--check', 'git.push')
        check = json.loads(ahead.stdout)['checks'][0]
        self.assertEqual(check['status'], 'incomplete')
        self.assertIn('provisional', check['findings'][0]['title'])
        self.assertEqual(check['findings'][0]['severity'], 'information')
        self.assertFalse((self.repo / '.git/FETCH_HEAD').exists())

    def test_explicit_fetch_refreshes_comparisons_without_changing_work_or_running_hooks(self):
        remote = Path(self.temp.name) / 'remote.git'
        subprocess.check_call(['git', 'init', '--bare', '-q', str(remote)], env=self.env)
        self.git('remote', 'add', 'origin', str(remote))
        self.git('push', '-u', 'origin', 'main')
        self.git('--git-dir', str(remote), 'update-ref', 'refs/heads/topic', self.git('rev-parse', 'HEAD').decode().strip())
        hook = self.repo / '.git/hooks/reference-transaction'
        marker = self.repo / 'hook-ran'
        hook.write_text('#!/bin/sh\ntouch "' + str(marker) + '"\n')
        hook.chmod(0o700)
        self.git('config', 'core.hooksPath', str(hook.parent))
        (self.repo / 'README.md').write_text('Local changes to preserve\n')
        paths = [self.repo / n for n in ['.git/HEAD', '.git/index', '.git/config', 'README.md']]
        before = [p.read_bytes() for p in paths]
        checks = ('--check', 'git.push', '--check', 'git.pull', '--check', 'git.diverged',
                  '--check', 'git.unpublishedBranches', '--check', 'git.upstream')
        result = self.check('--fetch', *checks)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report = json.loads(result.stdout)
        self.assertTrue(all(c['status'] == 'passed' for c in report['checks']))
        self.assertIn('successfully refreshed', report['remoteRefs'])
        self.assertTrue(self.git('rev-parse', 'refs/remotes/origin/topic'))
        self.assertEqual([p.read_bytes() for p in paths], before)
        self.assertFalse(marker.exists())
        # A later invocation must not infer freshness from FETCH_HEAD's mtime.
        self.assertEqual(self.check(*checks).returncode, 3)

    def test_failed_fetch_keeps_local_findings_and_redacts_provider_errors(self):
        good = Path(self.temp.name) / 'good.git'
        subprocess.check_call(['git', 'init', '--bare', '-q', str(good)], env=self.env)
        self.git('remote', 'add', 'a-good', str(good))
        self.git('push', 'a-good', 'main')
        self.git('remote', 'add', 'origin', str(Path(self.temp.name) / 'secret-remote-token'))
        self.git('update-ref', 'refs/remotes/origin/main', 'HEAD')
        self.git('config', 'branch.main.remote', 'origin')
        self.git('config', 'branch.main.merge', 'refs/heads/main')
        self.git('commit', '--allow-empty', '-m', 'Unpublished work')
        result = self.check('--fetch', '--check', 'git.push', '--check', 'files.readme')
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        report = json.loads(result.stdout)
        check = next(c for c in report['checks'] if c['id'] == 'git.push')
        self.assertEqual(check['status'], 'incomplete')
        self.assertIn('failed', check['reason'])
        self.assertIn('provisional', check['findings'][0]['title'])
        self.assertIn('failed', report['remoteRefs'])
        self.assertNotIn('secret-remote-token', result.stdout + result.stderr)
        self.assertEqual(next(c for c in report['checks'] if c['id'] == 'files.readme')['status'], 'passed')

    def test_sibling_links_check_existence_and_keep_real_missing_targets(self):
        sibling = Path(self.temp.name) / 'sibling repo'
        sibling.mkdir()
        subprocess.check_call(['git', 'init', '-q', str(sibling)], env=self.env)
        (sibling / 'README.md').write_text('Sibling documentation')
        (self.repo / 'README.md').write_text('[Sibling](../sibling%20repo/README.md)\n')
        self.assertEqual(self.check('--check', 'docs.brokenLinks').returncode, 0)
        (self.repo / 'README.md').write_text('[Sibling](../sibling%20repo/missing.md)\n[Local](missing.md)')
        result = self.check('--check', 'docs.brokenLinks')
        check = json.loads(result.stdout)['checks'][0]
        self.assertEqual(check['status'], 'findings')
        self.assertIn('../sibling%20repo/missing.md', check['findings'][0]['evidence'])
        # An unsafe target must not discard known broken links in the same document.
        with (self.repo / 'README.md').open('a') as stream:
            stream.write('\n[Outside](../../private-file.md)')
        result = self.check('--check', 'docs.brokenLinks')
        check = json.loads(result.stdout)['checks'][0]
        self.assertEqual(check['status'], 'incomplete')
        self.assertTrue(check['findings'])
        self.assertIn('missing.md', check['findings'][0]['evidence'])

    def test_partial_scan_retains_findings_and_cannot_claim_clean(self):
        missing = self.repo / 'a-missing.py'
        missing.write_text('fixture')
        conflict = self.repo / 'z-conflict.py'
        conflict.write_text('<<<<<<< HEAD\nleft\n=======\nright\n>>>>>>> topic\n')
        self.git('add', missing.name, conflict.name)
        missing.unlink()
        paths = [self.repo / '.git' / name for name in ['HEAD', 'index', 'config']]
        before = [p.read_bytes() for p in paths]
        result = self.check('--check', 'files.mergeMarkers')
        check = json.loads(result.stdout)['checks'][0]
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(check['status'], 'incomplete')
        self.assertEqual([f['subject'] for f in check['findings']], [conflict.name])
        self.assertIn(missing.name, check['reason'])
        self.assertEqual([p.read_bytes() for p in paths], before)
        conflict.write_text("print('repaired')\n")
        result = self.check('--check', 'files.mergeMarkers')
        check = json.loads(result.stdout)['checks'][0]
        self.assertEqual(result.returncode, 3)
        self.assertEqual(check['status'], 'incomplete')
        self.assertEqual(check['findings'], [])
        missing.write_text('restored')
        self.assertEqual(self.check('--check', 'files.mergeMarkers').returncode, 0)

    def test_deleted_file_diagnostic_is_repository_relative(self):
        path = self.repo / 'docs' / 'nested' / 'SKILL.md'
        path.parent.mkdir(parents=True)
        path.write_text('Fixture')
        self.git('add', 'docs/nested/SKILL.md')
        path.unlink()
        result = self.check('--check', 'files.secrets', '--check', 'docs.brokenLinks')
        self.assertEqual(result.returncode, 3)
        for check in json.loads(result.stdout)['checks']:
            self.assertEqual(check['status'], 'incomplete')
            self.assertIn('docs/nested/SKILL.md', check['reason'])
            self.assertNotIn(str(self.repo), check['reason'])


if __name__ == '__main__':
    unittest.main()
