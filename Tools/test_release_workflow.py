"""Check release safety without compiling, signing, or accessing GitHub."""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = Path('.codex/skills/build-release/scripts')
spec = importlib.util.spec_from_file_location('release_version', ROOT / SCRIPTS / 'release-version.py')
metadata = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metadata)


def workflow_script(name):
    lines = (ROOT / '.github/workflows/release.yml').read_text().splitlines()
    start = lines.index('      - name: ' + name)
    start = next(i for i in range(start, len(lines)) if lines[i] == '        run: |') + 1
    result = []
    for line in lines[start:]:
        if line and not line.startswith('          '):
            break
        result.append(line[10:])
    return '\n'.join(result)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.repo = self.base / 'repo'
        self.repo.mkdir()
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        self.log = self.base / 'commands.jsonl'
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                        REAL_GIT=shutil.which('git'), STUB_LOG=str(self.log),
                        GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1',
                        GIT_AUTHOR_NAME='Release Test', GIT_AUTHOR_EMAIL='test@example.invalid',
                        GIT_COMMITTER_NAME='Release Test', GIT_COMMITTER_EMAIL='test@example.invalid',
                        GH_REPO='tsilva/repoman', RELEASE_TAG='v0.1.1', RELEASE_VERSION='0.1.1')
        stub = f'''#!{shutil.which('python3')}
import json, os, pathlib, shutil, subprocess, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['STUB_LOG'], 'a') as f:
    f.write(json.dumps([name, *args]) + '\\n')
if name == 'git':
    if args[0] == 'fetch':
        sys.exit(0)
    sys.exit(subprocess.call([os.environ['REAL_GIT'], *args]))
if name == 'gh':
    if os.environ.get('STUB_GH_ERROR'):
        sys.exit(17)
    if args[:2] == ['repo', 'view']:
        print('tsilva/repoman')
    elif args[:2] == ['release', 'download']:
        output = pathlib.Path(args[args.index('--dir') + 1]); output.mkdir()
        for source in pathlib.Path('dist').iterdir():
            shutil.copy2(source, output / source.name)
        if os.environ.get('STUB_CORRUPT_DOWNLOAD'):
            next(output.glob('*.dmg')).write_bytes(b'corrupt download')
    elif args and args[0] == 'api':
        if any('/releases' in x for x in args):
            print(os.environ.get('STUB_RELEASES', ''))
        elif '.object.type' in args:
            print(os.environ.get('STUB_TAG_TYPE', 'commit'))
        else:
            print(os.environ['RELEASE_SHA'])
    sys.exit(0)
if name == 'uname':
    print('Darwin'); sys.exit(0)
if name == 'swift':
    sys.exit(0)
if name == 'xcodebuild':
    if args == ['-version']:
        print('Xcode 27.0'); sys.exit(0)
    derived = pathlib.Path(args[args.index('-derivedDataPath') + 1])
    app = derived / 'Build/Products/Release/RepoMan.app/Contents'
    (app / 'MacOS').mkdir(parents=True)
    (app / 'Resources').mkdir()
    (app / 'Info.plist').write_text('mock plist')
    (app / 'MacOS/RepoMan').write_bytes(b'mock executable')
    (app / 'Resources/AppIcon.icns').write_bytes(b'mock icon')
    sys.exit(0)
if name == 'plutil':
    values = {{'CFBundleIdentifier': 'com.tsilva.RepoMan', 'CFBundleShortVersionString': '0.1.1', 'LSMinimumSystemVersion': '27.0'}}
    field = args[args.index('-extract') + 1]
    print(os.environ.get('STUB_' + field, values[field])); sys.exit(0)
if name == 'lipo':
    print(os.environ.get('STUB_ARCH', 'arm64')); sys.exit(0)
if name == 'codesign':
    if '--verify' in args and os.environ.get('STUB_INVALID_SIGNATURE'):
        sys.exit(1)
    if '-dv' in args:
        print(os.environ.get('STUB_SIGNATURE', 'Signature=adhoc'))
    sys.exit(0)
if name == 'ditto':
    shutil.copytree(args[0], args[1]); sys.exit(0)
if name == 'SetFile':
    sys.exit(91)  # Finder flags must never mutate a signed app during packaging.
if name == 'hdiutil':
    if args[0] == 'create':
        pathlib.Path(args[-1]).write_bytes(b'mock dmg')
    sys.exit(0)
sys.exit(91)  # Never allow a real native build or disk-image operation.
'''
        for command in ['git', 'gh', 'uname', 'swift', 'xcodebuild', 'plutil', 'lipo', 'codesign', 'hdiutil', 'ditto', 'SetFile']:
            path = self.bin / command
            path.write_text(stub)
            path.chmod(0o755)
        (self.repo / SCRIPTS).mkdir(parents=True)
        for name in ['validate-release.sh', 'build-release.sh', 'release-version.py']:
            shutil.copy2(ROOT / SCRIPTS / name, self.repo / SCRIPTS / name)
        (self.repo / 'Tools').mkdir()
        shutil.copy2(ROOT / 'Tools/package-dmg.sh', self.repo / 'Tools/package-dmg.sh')
        (self.repo / 'RepoMan.xcodeproj').mkdir()
        self.project = self.repo / 'RepoMan.xcodeproj/project.pbxproj'
        self.project.write_text('MARKETING_VERSION = 0.1.1;\nMARKETING_VERSION = 0.1.1;\n')
        self.git('init', '-b', 'main')
        self.git('add', '.')
        self.git('commit', '-m', 'Test app')
        self.env['RELEASE_SHA'] = self.git('rev-parse', 'HEAD')
        self.git('update-ref', 'refs/remotes/origin/main', self.env['RELEASE_SHA'])

    def git(self, *args):
        return subprocess.check_output([self.env['REAL_GIT'], *args], cwd=self.repo,
                                       env=self.env, text=True, stderr=subprocess.DEVNULL).strip()

    def commands(self):
        return [json.loads(x) for x in self.log.read_text().splitlines()] if self.log.exists() else []

    def package_fixture(self):
        app = self.base / 'RepoMan.app'
        (app / 'Contents').mkdir(parents=True)
        (app / 'Contents/Info.plist').write_text('mock plist')
        design = self.repo / 'image-assets/dmg'
        design.mkdir(parents=True)
        for name in ['background.tiff', 'finder-layout.DSStore']:
            (design / name).write_bytes(b'mock design')
        return app, self.base / 'RepoMan.dmg'

    def test_packaging_preserves_signed_app_and_checks_it_before_creating_image(self):
        app, output = self.package_fixture()
        result = subprocess.run(['bash', str(self.repo / 'Tools/package-dmg.sh'), str(app), str(output)],
                                cwd=self.repo, env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(output.is_file())
        commands = self.commands()
        verify = next(i for i, args in enumerate(commands) if args[0] == 'codesign' and '--verify' in args)
        create = next(i for i, args in enumerate(commands) if args[:2] == ['hdiutil', 'create'])
        self.assertLess(verify, create)

    def test_packaging_rejects_invalid_copied_app_before_creating_image(self):
        app, output = self.package_fixture()
        self.env['STUB_INVALID_SIGNATURE'] = '1'
        result = subprocess.run(['bash', str(self.repo / 'Tools/package-dmg.sh'), str(app), str(output)],
                                cwd=self.repo, env=self.env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(output.exists())
        self.assertFalse(any(args[0] == 'hdiutil' for args in self.commands()))

    def test_reads_consistent_project_version_without_xcode(self):
        self.assertEqual(metadata.project_version(self.project), '0.1.1')
        self.assertEqual(self.commands(), [])

    def test_rejects_inconsistent_or_invalid_metadata(self):
        for text in ['MARKETING_VERSION = 0.1.1;\nMARKETING_VERSION = 0.2.0;',
                     'MARKETING_VERSION = 0.1.1;',
                     'MARKETING_VERSION = invalid;\nMARKETING_VERSION = invalid;']:
            with self.subTest(text=text):
                self.project.write_text(text)
                with self.assertRaises(ValueError):
                    metadata.project_version(self.project)

    def test_tag_must_match_source_metadata(self):
        result = subprocess.run([shutil.which('python3'), str(self.repo / SCRIPTS / 'release-version.py'),
                                 '--tag', 'v9.0.0'], env=self.env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('must match', result.stderr)

    def test_validation_dispatches_upstream_sha_without_building_local_work(self):
        self.project.write_text('uncommitted work')
        result = subprocess.run(['bash', str(self.repo / SCRIPTS / 'validate-release.sh')],
                                cwd=self.repo, env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        call = next(x for x in self.commands() if x[:3] == ['gh', 'workflow', 'run'])
        self.assertIn('ref=' + self.env['RELEASE_SHA'], call)
        self.assertTrue(all(x[0] in ('git', 'gh') for x in self.commands()))
        self.assertEqual(self.project.read_text(), 'uncommitted work')

    def test_validation_stops_on_api_failure(self):
        self.env['STUB_GH_ERROR'] = '1'
        result = subprocess.run(['bash', str(self.repo / SCRIPTS / 'validate-release.sh')],
                                cwd=self.repo, env=self.env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(x[:3] == ['gh', 'workflow', 'run'] for x in self.commands()))

    def test_invalid_bundle_gates_stop_before_packaging(self):
        for field, bad in [('CFBundleIdentifier', 'other.app'), ('CFBundleShortVersionString', '9.0.0'),
                           ('LSMinimumSystemVersion', '26.0'), ('ARCH', 'x86_64'),
                           ('SIGNATURE', 'Signature=developer-id')]:
            with self.subTest(field=field):
                self.env['STUB_' + field] = bad
                result = subprocess.run(['bash', str(self.repo / SCRIPTS / 'build-release.sh'),
                                         '--version', '0.1.1', '--output-dir', str(self.base / 'artifacts')],
                                        cwd=self.repo, env=self.env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertFalse(any(x[0] == 'hdiutil' for x in self.commands()))
                del self.env['STUB_' + field]

    def test_stale_artifact_directory_is_rejected(self):
        artifacts = self.base / 'artifacts'; artifacts.mkdir()
        (artifacts / 'stale.dmg').write_bytes(b'stale')
        result = subprocess.run(['bash', str(self.repo / SCRIPTS / 'build-release.sh'),
                                 '--version', '0.1.1', '--output-dir', str(artifacts)],
                                cwd=self.repo, env=self.env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('must be empty', result.stderr)
        self.assertFalse(any(x[0] == 'swift' for x in self.commands()))

    def candidate(self):
        dist = self.repo / 'dist'; dist.mkdir()
        artifact = dist / 'RepoMan-v0.1.1-macOS-arm64-adhoc.dmg'
        artifact.write_bytes(b'validated candidate')
        checksum = hashlib.sha256(artifact.read_bytes()).hexdigest()
        artifact.with_suffix('.dmg.sha256').write_text(checksum + '  ' + artifact.name + '\n')
        shim = self.bin / 'sha256sum'
        shim.write_text('#!/bin/sh\nexec shasum -a 256 "$@"\n'); shim.chmod(0o755)
        return artifact

    def run_step(self, name):
        return subprocess.run(['bash', '-c', workflow_script(name)], cwd=self.repo,
                              env=self.env, text=True, capture_output=True)

    def test_valid_candidate_passes_publication_gate(self):
        self.candidate()
        result = self.run_step('Verify candidate before publication')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_corrupt_candidate_fails_publication_gate(self):
        self.candidate().write_bytes(b'corrupt')
        self.assertNotEqual(self.run_step('Verify candidate before publication').returncode, 0)

    def test_existing_release_fails_publication_gate(self):
        self.candidate()
        self.env['STUB_RELEASES'] = 'v0.1.1'
        self.assertNotEqual(self.run_step('Verify candidate before publication').returncode, 0)

    def test_api_failure_fails_publication_gate(self):
        self.candidate()
        self.env['STUB_GH_ERROR'] = '1'
        self.assertNotEqual(self.run_step('Verify candidate before publication').returncode, 0)

    def test_fresh_downloads_and_annotated_tag_verify(self):
        self.candidate()
        self.env['STUB_TAG_TYPE'] = 'tag'
        result = self.run_step('Verify published source and fresh downloads')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_corrupt_public_download_fails_verification(self):
        self.candidate()
        self.env['STUB_CORRUPT_DOWNLOAD'] = '1'
        self.assertNotEqual(self.run_step('Verify published source and fresh downloads').returncode, 0)


if __name__ == '__main__':
    unittest.main(verbosity=2)
