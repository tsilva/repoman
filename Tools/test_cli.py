"""Exercise the built CLI against isolated local fixtures; no network or installs."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

BINARY = Path(sys.argv.pop(1)).resolve() if len(sys.argv) > 1 else Path('.build/debug/repoman').resolve()


class CLITests(unittest.TestCase):
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
        self.assertEqual(report.returncode, 1, report.stderr)
        remote = [c for c in json.loads(report.stdout)['checks'] if c['id'] == 'github.description']
        self.assertEqual(remote[0]['status'], 'skipped')
        self.assertEqual([p.read_bytes() for p in paths], before)
        self.assertFalse(marker.exists())
        self.assertFalse((self.repo / '.git/FETCH_HEAD').exists())

    def test_incomplete_policy_and_unborn_checkout(self):
        (self.repo / '.repoman.json').write_text('invalid')
        result = self.check('--check', 'dependencies.safeguards')
        self.assertEqual(result.returncode, 1)
        self.assertEqual(json.loads(result.stdout)['checks'][0]['status'], 'incomplete')
        unborn = Path(self.temp.name) / 'unborn'
        unborn.mkdir()
        subprocess.check_call(['git', 'init', '-q', str(unborn)], env=self.env)
        result = self.cli('check', '--repo', str(unborn), '--check', 'files.readme', '--format', 'json')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIsNone(json.loads(result.stdout)['head'])


    def test_unfetched_local_counts_are_provisional_even_when_aligned(self):
        self.git('remote', 'add', 'origin', str(Path(self.temp.name) / 'unreachable'))
        self.git('update-ref', 'refs/remotes/origin/main', 'HEAD')
        self.git('config', 'branch.main.remote', 'origin')
        self.git('config', 'branch.main.merge', 'refs/heads/main')
        aligned = self.check('--check', 'git.push')
        self.assertEqual(aligned.returncode, 1)
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
        self.assertEqual(self.check(*checks).returncode, 1)


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
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
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


if __name__ == '__main__':
    unittest.main()
