#!/usr/bin/env python3
"""Install user LaunchAgents for already-approved GA4 broker profiles; never handle tokens."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import sys


PROFILES = ("ga4-reporting", "ga4-realtime")
PREFIX = "com.tsilva.RepoMan.token-renewal."


def job(home, profile):
    if profile not in PROFILES:
        raise ValueError("Unreviewed renewal profile")
    logs = home / "Library/Logs/RepoMan"
    return {
        "Label": PREFIX + profile,
        "ProgramArguments": [str(home / ".local/bin/infisical-token-broker"), "refresh", profile],
        "RunAtLoad": True,
        # Calendar scheduling coalesces missed renewals on wake; an interval timer does not.
        "StartCalendarInterval": [{"Minute": minute} for minute in range(0, 60, 10)],
        "ProcessType": "Standard",
        "LimitLoadToSessionType": "Aqua",
        "ThrottleInterval": 60,
        "Umask": 0o077,
        "StandardOutPath": str(logs / (profile + "-renewal.jsonl")),
        "StandardErrorPath": str(logs / (profile + "-renewal-errors.log")),
    }


def validate_existing(path, expected):
    if path.is_symlink():
        raise ValueError("Refusing a linked LaunchAgent: " + path.name)
    if path.exists():
        info = path.stat()
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or info.st_mode & 0o022 or plistlib.loads(path.read_bytes()) != expected):
            raise ValueError("Existing LaunchAgent differs or has unsafe ownership: " + path.name)


def run(arguments):
    return subprocess.run(arguments, capture_output=True, timeout=120)


def install(home, check=False):
    broker = home / ".local/bin/infisical-token-broker"
    if not broker.is_file() or not os.access(broker, os.X_OK):
        raise ValueError("Install the reviewed token broker first")
    agents = home / "Library/LaunchAgents"
    specs = [(agents / (PREFIX + profile + ".plist"), job(home, profile)) for profile in PROFILES]
    # Check every existing target and both pinned profiles before creating or starting anything.
    for path, spec in specs:
        validate_existing(path, spec)
        result = run([str(broker), "check", spec["ProgramArguments"][-1]])
        if result.returncode:
            raise ValueError("Approved broker profile unavailable; private output withheld")
    if check:
        return {"status": "ready", "profiles": list(PROFILES), "credentials_requested": False}

    agents.mkdir(parents=True, exist_ok=True)
    logs = home / "Library/Logs/RepoMan"
    logs.mkdir(parents=True, exist_ok=True)
    domain = "gui/" + str(os.getuid())
    for path, spec in specs:
        # launchd only gets the broker command and approved profile name, never credential material.
        for key in ("StandardOutPath", "StandardErrorPath"):
            log = Path(spec[key])
            descriptor = os.open(log, os.O_CREAT | os.O_APPEND | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
            with os.fdopen(descriptor, "ab") as stream:
                info = os.fstat(stream.fileno())
                if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                    raise ValueError("Unsafe renewal log file")
        if not path.exists():
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(descriptor, "wb") as stream:
                stream.write(plistlib.dumps(spec, sort_keys=True))
        if run(["/bin/launchctl", "print", domain + "/" + spec["Label"]]).returncode:
            if run(["/bin/launchctl", "bootstrap", domain, str(path)]).returncode:
                raise ValueError("LaunchAgent could not start; check the logged-in GUI session")
    return {"status": "installed", "profiles": list(PROFILES), "renewal_minutes": 10,
            "start_at_login": True, "wake_catchup": True, "credentials_in_app": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Validate profiles and installation targets without changes")
    args = parser.parse_args()
    try:
        if sys.platform != "darwin":
            raise ValueError("Automatic renewal requires macOS launchd")
        print(json.dumps(install(Path.home(), check=args.check)))
        return 0
    except (ValueError, OSError, subprocess.SubprocessError, plistlib.InvalidFileException):
        print("Traffic renewal setup failed; existing profiles and credential routes were not changed. Check local installation targets and approved broker registration.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
