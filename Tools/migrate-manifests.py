#!/usr/bin/env python3
"""Consolidate root RepoMan manifests without changing Git state.

Python 3.11+. Dry-run by default; --apply requires an independent backup directory.
Synchronize selected repositories and review their instructions before applying.
Only the three named manifest files are read or changed.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import tempfile
import tomllib

NAMES = (".repoman.json", ".repoman.yaml", ".repo-metadata.toml")


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate JSON key")
        result[key] = value
    return result


def read_json(source):
    value = json.loads(source, object_pairs_hook=unique_object,
                       parse_constant=lambda _: (_ for _ in ()).throw(ValueError("Invalid JSON constant")))
    if not isinstance(value, dict):
        raise ValueError("Expected a manifest object")
    return value


def legacy_yaml(source):
    """Parse the historical manifest's scalar/block-map subset, never general YAML."""
    result = {}
    stack = [(-1, result)]
    for raw in source.splitlines():
        if not raw.strip() or raw.lstrip().startswith("#") or raw == "---":
            continue
        match = re.fullmatch(r"( *)([A-Za-z0-9.-]+):(?: +(.*))?", raw)
        if not match:
            raise ValueError("Unsupported legacy YAML; review manually")
        indent, key, text = match.groups()
        while stack[-1][0] >= len(indent):
            stack.pop()
        parent = stack[-1][1]
        if key in parent:
            raise ValueError("Duplicate legacy YAML key")
        if text is None:
            value = {}
        elif text.startswith('"'):
            value = json.loads(text)
        elif text.startswith("'"):
            if not re.fullmatch(r"'(?:[^']|'')*'", text):
                raise ValueError("Unsupported quoted YAML value")
            value = text[1:-1].replace("''", "'")
        elif text == "{}":
            value = {}
        elif text == "null":
            value = None
        elif key == "version" and text == "1":
            value = 1
        else:
            if text[0] in "[&*!>|{`" or " #" in text:
                raise ValueError("Unsupported legacy YAML scalar; review manually")
            value = text
        parent[key] = value
        if isinstance(value, dict):
            stack.append((len(indent), value))
    if result.get("version") != 1 or not set(result) <= {"version", "tagline", "github-url", "vercel-project-id", "websites"}:
        raise ValueError("Unsupported legacy manifest fields or version")
    return result


def plan(repo):
    repo = repo.resolve(strict=True)
    if not (repo / ".git").exists():
        raise ValueError("Select a Git checkout root")
    originals = {}
    for name in NAMES:
        path = repo / name
        try:
            info = path.lstat()
        except FileNotFoundError:
            continue
        if not stat.S_ISREG(info.st_mode) or info.st_size > 1_048_576:
            raise ValueError("Manifest must be a bounded regular file")
        originals[name] = path.read_bytes()
    if not any(name in originals for name in NAMES[1:]):
        return None
    result = read_json(originals[".repoman.json"]) if ".repoman.json" in originals else {"version": 1}
    if type(result.get("version", 1)) is not int or result.get("version", 1) != 1:
        raise ValueError("Unsupported JSON manifest version")
    result.setdefault("version", 1)

    def merge(key, value):
        if key in result and result[key] != value:
            raise ValueError("Conflicting manifest declarations: " + key)
        result[key] = value

    if ".repoman.yaml" in originals:
        for key, value in legacy_yaml(originals[".repoman.yaml"].decode("utf-8")).items():
            merge(key, value)
    if ".repo-metadata.toml" in originals:
        metadata = tomllib.loads(originals[".repo-metadata.toml"].decode("utf-8"))
        if not set(metadata) <= {"short-name", "domains"}:
            raise ValueError("Unknown TOML fields; refusing data loss")
        if "short-name" in metadata:
            if not isinstance(metadata["short-name"], str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,20}", metadata["short-name"]):
                raise ValueError("Invalid short name")
            merge("short-name", metadata["short-name"])
        if "domains" in metadata:
            domains = metadata["domains"]
            if not isinstance(domains, list) or not all(isinstance(d, str) for d in domains):
                raise ValueError("Invalid legacy domains")
            domains = [d.lower() for d in domains]
            if len(domains) != len(set(domains)):
                raise ValueError("Duplicate legacy domains")
            if "websites" in result and set(result["websites"]) != set(domains):
                raise ValueError("Conflicting domain inventories; review manually")
            result.setdefault("websites", {d: {"url": "https://" + d + "/"} for d in domains})
    encoded = (json.dumps(result, indent=2, ensure_ascii=False, allow_nan=False) + "\n").encode()
    return repo, originals, encoded


def apply(candidate, backup_dir):
    repo, originals, encoded = candidate
    backup = backup_dir.resolve() / repo.name
    backup.mkdir(parents=True, exist_ok=False, mode=0o700)
    for name, data in originals.items():
        (backup / name).write_bytes(data)
    # Recheck every input, including absence, immediately before replacement.
    for name in NAMES:
        path = repo / name
        if name in originals:
            if path.is_symlink() or not path.is_file() or path.read_bytes() != originals[name]:
                raise ValueError("Manifest changed during migration")
        elif path.exists() or path.is_symlink():
            raise ValueError("Manifest appeared during migration")
    target = repo / NAMES[0]
    mode = stat.S_IMODE(target.stat().st_mode) if target.exists() else 0o644
    descriptor, temporary = tempfile.mkstemp(prefix=".repoman-migration-", dir=repo)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    if target.read_bytes() != encoded:
        raise ValueError("JSON readback failed; legacy files retained")
    for name in NAMES[1:]:
        if name in originals:
            path = repo / name
            if path.is_symlink() or path.read_bytes() != originals[name]:
                raise ValueError("Legacy file changed; refusing removal")
            path.unlink()
    receipt = {"repository": str(repo), "before": {k: hashlib.sha256(v).hexdigest() for k, v in originals.items()},
               "after": hashlib.sha256(encoded).hexdigest()}
    (backup / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", action="append", type=Path, required=True)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--backup-dir", type=Path)
    args = parser.parse_args()
    if args.apply and args.backup_dir is None:
        parser.error("--apply requires --backup-dir")
    candidates = [plan(repo) for repo in args.repo]
    for candidate in candidates:
        if candidate:
            if args.apply:
                apply(candidate, args.backup_dir)
            print(candidate[0].name + (": migrated" if args.apply else ": ready"))


if __name__ == "__main__":
    main()
