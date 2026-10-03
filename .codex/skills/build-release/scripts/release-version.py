#!/usr/bin/env python3
"""Read RepoMan release metadata without running Xcode or compiling the app."""

import argparse
from pathlib import Path
import re


def project_version(project):
    versions = re.findall(r"\bMARKETING_VERSION\s*=\s*([^;]+);", project.read_text())
    versions = [value.strip() for value in versions]
    if len(versions) != 2 or len(set(versions)) != 1 or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", versions[0]):
        raise ValueError("Both RepoMan build configurations must have the same X.Y.Z MARKETING_VERSION")
    return versions[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", help="Release tag to match, or workflow_dispatch for validation")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[4]
    try:
        version = project_version(root / "RepoMan.xcodeproj/project.pbxproj")
        if args.tag not in (None, "workflow_dispatch", "v" + version):
            raise ValueError("Release tag must match the committed MARKETING_VERSION")
    except ValueError as error:
        parser.exit(1, str(error) + "\n")
    print("number=" + version)


if __name__ == "__main__":
    main()
