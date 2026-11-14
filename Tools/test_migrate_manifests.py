import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("manifest_migration", Path(__file__).with_name("migrate-manifests.py"))
migration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migration)


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "repo"
        self.root.mkdir()
        (self.root / ".git").mkdir()
        self.backups = Path(self.temp.name) / "backups"

    def write(self, name, source):
        (self.root / name).write_text(source)

    def test_preserves_policy_null_identity_and_evidence_then_is_idempotent(self):
        policy = {"version": 1, "exceptions": {"dependencies.releaseAge": {"npm:fixture@1#age": "Exact audit"}}}
        self.write(".repoman.json", json.dumps(policy))
        self.write(".repo-metadata.toml", 'short-name="fixture"\ndomains=["site.tsilva.eu"]\n')
        self.write(".repoman.yaml", 'version: 1\ngithub-url: null\nwebsites:\n  site.tsilva.eu:\n    url: https://site.tsilva.eu/\n    checked-on: 2026-11-03\n')
        candidate = migration.plan(self.root)
        migration.apply(candidate, self.backups)
        actual = json.loads((self.root / ".repoman.json").read_text())
        self.assertEqual(actual["exceptions"], policy["exceptions"])
        self.assertIsNone(actual["github-url"])
        self.assertEqual(actual["short-name"], "fixture")
        self.assertEqual(actual["websites"]["site.tsilva.eu"]["checked-on"], "2026-11-03")
        self.assertFalse((self.root / ".repoman.yaml").exists())
        self.assertFalse((self.root / ".repo-metadata.toml").exists())
        self.assertEqual(json.loads((self.backups / "repo/.repoman.json").read_text()), policy)
        self.assertIsNone(migration.plan(self.root))

    def test_conflicts_and_unknown_fields_refuse_data_loss(self):
        self.write(".repoman.json", '{"version":1,"tagline":"First"}')
        self.write(".repoman.yaml", 'version: 1\ntagline: Second\n')
        with self.assertRaisesRegex(ValueError, "Conflicting"):
            migration.plan(self.root)
        self.write(".repoman.yaml", 'version: 1\n')
        self.write(".repo-metadata.toml", 'unknown="preserve me"\n')
        with self.assertRaisesRegex(ValueError, "Unknown TOML"):
            migration.plan(self.root)

    def test_changed_inputs_and_symlinks_are_not_overwritten(self):
        self.write(".repoman.yaml", "version: 1\n")
        candidate = migration.plan(self.root)
        self.write(".repoman.yaml", "version: 1\ntagline: Concurrent\n")
        with self.assertRaisesRegex(ValueError, "changed"):
            migration.apply(candidate, self.backups)
        self.assertFalse((self.root / ".repoman.json").exists())
        (self.root / ".repoman.yaml").unlink()
        (self.root / ".repoman.yaml").symlink_to(self.backups / "repo/.repoman.yaml")
        with self.assertRaisesRegex(ValueError, "regular"):
            migration.plan(self.root)

    def test_duplicate_keys_and_disagreeing_domains_are_rejected(self):
        self.write(".repoman.yaml", 'version: 1\nwebsites: {}\n')
        self.write(".repoman.json", '{"version":1,"version":1}')
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            migration.plan(self.root)
        self.write(".repoman.json", '{"version":1}')
        self.write(".repo-metadata.toml", 'domains=["site.tsilva.eu"]')
        with self.assertRaisesRegex(ValueError, "Conflicting domain"):
            migration.plan(self.root)


if __name__ == "__main__":
    unittest.main()
