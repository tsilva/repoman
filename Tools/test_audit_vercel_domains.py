"""Run with python3 -m unittest discover -s Tools -p 'test_*.py'."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("domain_audit", Path(__file__).with_name("audit-vercel-domains.py"))
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class DomainAuditTests(unittest.TestCase):
    def test_assigned_domains_include_apex_and_only_its_subdomains(self):
        values = {"domains": [{"name": name} for name in ["tsilva.eu", "APP.tsilva.eu", "eviltsilva.eu", "tsilva.eu.evil.com", "app.vercel.app"]]}
        self.assertEqual(audit.assigned_domains(values), ["app.tsilva.eu", "tsilva.eu"])

    def test_root_metadata_preserves_other_fields_and_detects_missing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / ".repo-metadata.toml"
            original = 'short-name = "app"\ndomains = ["APP.tsilva.eu"]\n[website]\ndomains = ["www.tsilva.eu"]\n'
            path.write_text(original)
            self.assertEqual(audit.compare_metadata(root, ["app.tsilva.eu", "www.tsilva.eu"]),
                             ("missing-domains", ["www.tsilva.eu"]))
            self.assertEqual(path.read_text(), original)
            self.assertEqual(audit.compare_metadata(root, ["app.tsilva.eu"]), ("covered", []))

    def test_invalid_metadata_cannot_report_covered(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for value in ['"app.tsilva.eu"', '["app.tsilva.eu", "APP.tsilva.eu"]', '["app.tsilva.eu", "https://app.tsilva.eu"]', '[false]', '[']:
                (root / ".repo-metadata.toml").write_text('domains = ' + value)
                self.assertEqual(audit.compare_metadata(root, ["app.tsilva.eu"])[0], "invalid-metadata")

    def test_older_projects_use_assigned_domains_without_recent_deployments(self):
        projects = [{"id": "old", "name": "old", "link": {"type": "github", "org": "tsilva", "repo": "old"}}]
        responses = {"/v9/projects": projects, "/v9/projects/old/domains": [{"name": "old.tsilva.eu"}]}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(audit, "local_repositories", return_value=({"tsilva/old": [root]}, {})), \
                 patch.object(audit, "vercel_api", side_effect=lambda endpoint, team: responses[endpoint]):
                rows = audit.audit(root, ["team"])
            self.assertEqual(rows[0]["status"], "missing-domains")
            self.assertEqual(rows[0]["missingDomains"], ["old.tsilva.eu"])

    def test_unlinked_project_requires_project_id_not_folder_name(self):
        project = {"id": "project-one", "name": "folder"}
        def response(endpoint, team):
            return [project] if endpoint == "/v9/projects" else [{"name": "folder.tsilva.eu"}]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for links, status in [({}, "unmapped-project"), ({"project-one": [root]}, "missing-domains"),
                                  ({"project-one": [root, root / "duplicate"]}, "ambiguous-checkout")]:
                with patch.object(audit, "local_repositories", return_value=({}, links)), \
                     patch.object(audit, "vercel_api", side_effect=response):
                    rows = audit.audit(root, ["team"])
                self.assertEqual(rows[0]["status"], status)

    def test_remote_identity_handles_ssh_and_https(self):
        for remote in ["git@github.com:tsilva/app.git", "https://github.com/tsilva/app.git", "ssh://git@github.com/tsilva/app.git"]:
            self.assertEqual(audit.github_repository(remote), "tsilva/app")
        self.assertIsNone(audit.github_repository("https://github.com.evil.example/tsilva/app.git"))


if __name__ == "__main__":
    unittest.main()
