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
                     ('check', '--repo', str(self.repo), '--repo', str(self.repo))]:
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


if __name__ == '__main__':
    unittest.main()
