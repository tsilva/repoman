"""Exercise renewal installation with fake broker/launchctl results and no service access."""
import importlib.util
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("traffic_renewal", Path(__file__).with_name("install-traffic-renewal.py"))
renewal = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renewal)


class TrafficRenewalTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="repoman-renewal-")
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        broker = self.home / ".local/bin/infisical-token-broker"
        broker.parent.mkdir(parents=True)
        broker.write_text("#!/bin/sh\nexit 0\n")
        broker.chmod(0o700)

    def result(self, arguments):
        return subprocess.CompletedProcess(arguments, 1 if "print" in arguments else 0, b"", b"")

    def test_only_approved_profiles_and_calendar_schedules_are_installed(self):
        with patch.object(renewal, "run", side_effect=self.result) as run:
            result = renewal.install(self.home)
        self.assertEqual(result["status"], "installed")
        paths = sorted((self.home / "Library/LaunchAgents").glob("*.plist"))
        self.assertEqual(len(paths), 2)
        for path in paths:
            body = plistlib.loads(path.read_bytes())
            self.assertEqual(body["ProgramArguments"][1], "refresh")
            self.assertIn(body["ProgramArguments"][2], renewal.PROFILES)
            self.assertEqual(body["StartCalendarInterval"], [{"Minute": n} for n in range(0, 60, 10)])
            self.assertTrue(body["RunAtLoad"])
            self.assertNotIn("KeepAlive", body)
            self.assertNotIn("EnvironmentVariables", body)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(sum("bootstrap" in call.args[0] for call in run.call_args_list), 2)

    def test_check_has_no_writes_and_does_not_refresh_credentials(self):
        with patch.object(renewal, "run", side_effect=self.result) as run:
            renewal.install(self.home, check=True)
        self.assertFalse((self.home / "Library").exists())
        self.assertTrue(all(call.args[0][1] == "check" for call in run.call_args_list))

    def test_changed_existing_job_is_rejected_before_any_job_starts(self):
        directory = self.home / "Library/LaunchAgents"
        directory.mkdir(parents=True)
        target = directory / (renewal.PREFIX + renewal.PROFILES[1] + ".plist")
        target.write_bytes(plistlib.dumps({"Label": "another-job"}))
        before = target.read_bytes()
        with patch.object(renewal, "run", side_effect=self.result) as run:
            with self.assertRaises(ValueError):
                renewal.install(self.home)
        self.assertFalse(any("bootstrap" in call.args[0] for call in run.call_args_list))
        self.assertEqual(target.read_bytes(), before)
        self.assertEqual(len(list(directory.iterdir())), 1)

    def test_failed_broker_preflight_prevents_installation(self):
        with patch.object(renewal, "run", return_value=subprocess.CompletedProcess([], 1, b"", b"private")):
            with self.assertRaises(ValueError):
                renewal.install(self.home)
        self.assertFalse((self.home / "Library").exists())

    def test_idempotent_install_preserves_loaded_jobs(self):
        with patch.object(renewal, "run", side_effect=self.result):
            renewal.install(self.home)
        with patch.object(renewal, "run", return_value=subprocess.CompletedProcess([], 0, b"", b"")) as run:
            renewal.install(self.home)
        self.assertFalse(any("bootstrap" in call.args[0] for call in run.call_args_list))

    def test_linked_target_is_rejected(self):
        directory = self.home / "Library/LaunchAgents"
        directory.mkdir(parents=True)
        target = directory / (renewal.PREFIX + renewal.PROFILES[0] + ".plist")
        target.symlink_to(self.home / "other")
        with patch.object(renewal, "run", side_effect=self.result):
            with self.assertRaises(ValueError):
                renewal.install(self.home)


if __name__ == "__main__":
    unittest.main()
