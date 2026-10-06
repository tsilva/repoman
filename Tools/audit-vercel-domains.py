#!/usr/bin/env python3
"""Read-only comparison of Vercel's assigned tsilva.eu domains with local metadata.

Python 3.11+, authenticated vercel CLI, and local Git checkouts are required.
No environment variables or credentials are requested. Does not edit repositories.
"""
import argparse
import json
import re
from pathlib import Path
import subprocess
import sys
import tomllib
from urllib.parse import urlparse


def command(arguments, *, directory=None):
    result = subprocess.run(arguments, cwd=directory, capture_output=True, text=True, timeout=45)
    if result.returncode:
        # CLI errors can include credential-bearing URLs; do not echo raw output.
        raise RuntimeError(f"{arguments[0]} command failed; check authentication and access")
    return result.stdout


def vercel_api(endpoint, team):
    value = json.loads(command(["vercel", "api", endpoint, "--scope", team, "--paginate", "--raw"]))
    return value


def github_repository(remote):
    if remote.startswith("git@github.com:"):
        remote = "https://github.com/" + remote.removeprefix("git@github.com:")
    url = urlparse(remote)
    if url.hostname != "github.com":
        return None
    return url.path.strip("/").removesuffix(".git").lower()


def local_repositories(root):
    repositories, links = {}, {}
    for path in sorted(root.iterdir()):
        if path.name.startswith(".") or not path.is_dir() or not (path / ".git").exists():
            continue
        try:
            # Exclude linked worktrees and never select a repository by folder name alone.
            git_dir = command(["git", "rev-parse", "--path-format=absolute", "--git-dir"], directory=path).strip()
            common = command(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"], directory=path).strip()
            if Path(git_dir).resolve() != Path(common).resolve():
                continue
            remote = command(["git", "remote", "get-url", "origin"], directory=path).strip()
            repository = github_repository(remote)
            if repository:
                repositories.setdefault(repository, []).append(path)
            link = path / ".vercel/project.json"
            if link.exists():
                project_id = json.loads(link.read_text()).get("projectId")
                if project_id:
                    links.setdefault(project_id, []).append(path)
        except (RuntimeError, ValueError, OSError):
            continue
    return repositories, links


def assigned_domains(payload):
    domains = payload.get("domains", []) if isinstance(payload, dict) else payload
    return sorted({item["name"].lower() for item in domains
                   if item["name"].lower() == "tsilva.eu" or item["name"].lower().endswith(".tsilva.eu")})


def domain_valid(domain):
    host = domain.lower()
    return (len(host) <= 253 and (host == "tsilva.eu" or host.endswith(".tsilva.eu"))
            and all(re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", part)
                    for part in host.split(".")))


def compare_metadata(path, expected):
    metadata = path / ".repo-metadata.toml"
    try:
        values = tomllib.loads(metadata.read_text()) if metadata.exists() else {}
        declared = values.get("domains", [])
        if (not isinstance(declared, list) or len(declared) > 32
                or not all(isinstance(d, str) and domain_valid(d) for d in declared)
                or len({d.lower() for d in declared}) != len(declared)):
            return "invalid-metadata", expected
        declared = {d.lower() for d in declared}
        missing = sorted(set(expected) - declared)
        return ("missing-domains" if missing else "covered"), missing
    except (OSError, ValueError):
        return "invalid-metadata", expected


def audit(root, teams):
    repositories, links = local_repositories(root)
    rows = []
    for team in teams:
        projects = vercel_api("/v9/projects", team)
        if isinstance(projects, dict):
            projects = projects.get("projects", [])
        for project in projects:
            # Assigned domains cover old deployments and projects absent from latestDeployments.
            domains = assigned_domains(vercel_api(f"/v9/projects/{project['id']}/domains", team))
            if not domains:
                continue
            link = project.get("link") or {}
            repository = (f"{link.get('org', '')}/{link.get('repo', '')}".lower()
                          if link.get("type") == "github" else None)
            paths = repositories.get(repository, []) if repository else links.get(project["id"], [])
            row = dict(team=team, project=project["name"], projectID=project["id"],
                       repository=repository, domains=domains)
            if len(paths) == 1:
                row["path"] = str(paths[0])
                row["status"], row["missingDomains"] = compare_metadata(paths[0], domains)
            else:
                row["status"] = "ambiguous-checkout" if paths else "unmapped-project"
                row["missingDomains"] = domains
            rows.append(row)
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True, help="Folder containing direct child repositories")
    parser.add_argument("--team", action="append", help="Vercel team slug (repeatable); defaults to every accessible team")
    parser.add_argument("--json", action="store_true", help="Output the full redacted inventory as JSON")
    args = parser.parse_args()
    try:
        teams = args.team
        if teams is None:
            payload = json.loads(command(["vercel", "teams", "ls", "--format", "json"]))
            if payload.get("pagination", {}).get("next") is not None:
                raise RuntimeError("Team listing is paginated; pass each team explicitly with --team")
            teams = [team["slug"] for team in payload["teams"]]
        if not teams:
            raise RuntimeError("No accessible Vercel teams; specify the intended account with --team")
        rows = audit(args.root.expanduser().resolve(), teams)
        if args.json:
            print(json.dumps(rows, indent=2))
        else:
            for row in rows:
                missing = ", ".join(row["missingDomains"])
                print(f"{row['team']}/{row['project']}: {row['status']}" + (f" ({missing})" if missing else ""))
        return 0 if all(row["status"] == "covered" for row in rows) else 1
    except (RuntimeError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(f"Domain audit unavailable: {type(error).__name__}; check CLI authentication, response format, and repository access.", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
