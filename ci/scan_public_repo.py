#!/usr/bin/env python3
"""Review the public tree and reachable Git history for sensitive material."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import subprocess
import sys
from dataclasses import dataclass

MAX_BLOB_BYTES = 2 * 1024 * 1024
SELF_PATH = "ci/scan_public_repo.py"
ALLOWLIST_PATH = "ci/public-sensitivity-allowlist.json"
SKIPPED_CONTROL_PATHS = {SELF_PATH, ALLOWLIST_PATH}


@dataclass(frozen=True)
class Rule:
    name: str
    expression: re.Pattern[str]


def joined(*parts: str) -> str:
    return "".join(parts)


RULES = [
    Rule("private-key-header", re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----")),
    Rule("github-classic-token", re.compile(re.escape(joined("gh", "p_")) + r"[A-Za-z0-9]{20,}")),
    Rule("github-fine-grained-token", re.compile(re.escape(joined("github", "_pat_")) + r"[A-Za-z0-9_]{20,}")),
    Rule("aws-access-key", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    Rule("google-api-key", re.compile(re.escape(joined("AI", "za")) + r"[A-Za-z0-9_-]{24,}")),
    Rule("tailscale-auth-key", re.compile(re.escape(joined("ts", "key-")) + r"[A-Za-z0-9_-]{12,}")),
    Rule("generic-secret-assignment", re.compile(r"(?i)\b(?:api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret|password|private[_-]?key)\b\s*[:=]\s*['\"]?[A-Za-z0-9+/_.=-]{12,}")),
    Rule("linux-user-home", re.compile(r"(?<![A-Za-z0-9])/(?:home|Users)/[A-Za-z0-9._-]+/")),
    Rule("windows-user-home", re.compile(r"(?i)\b[A-Z]:\\Users\\[A-Za-z0-9._ -]+\\")),
    Rule("tailnet-hostname", re.compile(r"\b[a-z0-9-]+\.[a-z0-9-]+\.ts\.net\b", re.IGNORECASE)),
    Rule("carrier-grade-private-address", re.compile(r"\b100\.(?:6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])(?:\.[0-9]{1,3}){2}\b")),
]


FindingKey = tuple[str, str, str]


def git(root: pathlib.Path, *args: str, text: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(["git", *args], cwd=root, check=False, capture_output=True, text=text)


def decode_text(data: bytes) -> str | None:
    if len(data) > MAX_BLOB_BYTES or b"\0" in data:
        return None
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return None


def load_allowlist(root: pathlib.Path) -> dict[FindingKey, str]:
    path = root / ALLOWLIST_PATH
    if not path.exists():
        return {}
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"invalid sensitivity allowlist JSON: {exc}") from exc
    if not isinstance(value, dict) or value.get("schema") != "pleiades.public-sensitivity-review/v1":
        raise RuntimeError("invalid sensitivity allowlist schema")
    entries = value.get("findings")
    if not isinstance(entries, list):
        raise RuntimeError("sensitivity allowlist findings must be a list")

    result: dict[FindingKey, str] = {}
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict):
            raise RuntimeError(f"allowlist finding {index} must be an object")
        path_value = entry.get("path")
        rule = entry.get("rule")
        digest = entry.get("line_sha256")
        classification = entry.get("classification")
        rationale = entry.get("rationale")
        if not isinstance(path_value, str) or not path_value or path_value.startswith("/") or ".." in pathlib.PurePosixPath(path_value).parts:
            raise RuntimeError(f"allowlist finding {index} has unsafe path")
        if not isinstance(rule, str) or rule not in {item.name for item in RULES}:
            raise RuntimeError(f"allowlist finding {index} has unknown rule")
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{12}", digest):
            raise RuntimeError(f"allowlist finding {index} has invalid line_sha256")
        if classification != "synthetic-decoy-fixture":
            raise RuntimeError(f"allowlist finding {index} uses unsupported classification")
        if not isinstance(rationale, str) or len(rationale.strip()) < 24:
            raise RuntimeError(f"allowlist finding {index} needs a substantive rationale")
        key = (path_value, rule, digest)
        if key in result:
            raise RuntimeError(f"duplicate sensitivity allowlist finding: {key}")
        result[key] = rationale.strip()
    return result


def scan_text(scope: str, identity: str, path: str, text: str, allowlist: dict[FindingKey, str]) -> tuple[list[str], list[str]]:
    if path in SKIPPED_CONTROL_PATHS:
        return [], []
    findings: list[str] = []
    reviewed: list[str] = []
    for line_number, line in enumerate(text.splitlines(), start=1):
        for rule in RULES:
            if not rule.expression.search(line):
                continue
            digest = hashlib.sha256(line.encode("utf-8")).hexdigest()[:12]
            key = (path, rule.name, digest)
            message = f"{scope}: {identity}:{path}:{line_number}: {rule.name} line_sha256={digest}"
            if key in allowlist:
                reviewed.append(message)
            else:
                findings.append(message)
    return findings, reviewed


def scan_current(root: pathlib.Path, allowlist: dict[FindingKey, str]) -> tuple[list[str], list[str]]:
    listed = git(root, "ls-files", "-z", text=False)
    if listed.returncode != 0:
        raise RuntimeError(listed.stderr.decode("utf-8", errors="replace"))
    findings: list[str] = []
    reviewed: list[str] = []
    for raw_path in listed.stdout.split(b"\0"):
        if not raw_path:
            continue
        path = raw_path.decode("utf-8")
        text = decode_text((root / path).read_bytes())
        if text is None:
            continue
        new_findings, new_reviewed = scan_text("current", "HEAD", path, text, allowlist)
        findings.extend(new_findings)
        reviewed.extend(new_reviewed)
    return findings, reviewed


def scan_history(root: pathlib.Path, allowlist: dict[FindingKey, str]) -> tuple[list[str], list[str]]:
    objects = git(root, "rev-list", "--objects", "--all")
    if objects.returncode != 0:
        raise RuntimeError(objects.stderr)
    findings: list[str] = []
    reviewed: list[str] = []
    visited: set[str] = set()
    for line in objects.stdout.splitlines():
        sha, separator, path = line.partition(" ")
        if not separator or not path or sha in visited or path in SKIPPED_CONTROL_PATHS:
            continue
        visited.add(sha)
        kind = git(root, "cat-file", "-t", sha)
        size = git(root, "cat-file", "-s", sha)
        if kind.returncode != 0 or kind.stdout.strip() != "blob" or size.returncode != 0:
            continue
        if int(size.stdout.strip()) > MAX_BLOB_BYTES:
            continue
        content = git(root, "cat-file", "blob", sha, text=False)
        if content.returncode != 0:
            continue
        text = decode_text(content.stdout)
        if text is None:
            continue
        new_findings, new_reviewed = scan_text("history", sha, path, text, allowlist)
        findings.extend(new_findings)
        reviewed.extend(new_reviewed)
    return findings, reviewed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--current-only", action="store_true")
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parents[1]
    allowlist = load_allowlist(root)
    findings, reviewed = scan_current(root, allowlist)
    if not args.current_only:
        history_findings, history_reviewed = scan_history(root, allowlist)
        findings.extend(history_findings)
        reviewed.extend(history_reviewed)

    if reviewed:
        print(f"REVIEWED: {len(set(reviewed))} exact synthetic-fixture finding(s) matched the checked allowlist")
    if findings:
        print("Public repository sensitivity scan requires review:", file=sys.stderr)
        for finding in sorted(set(findings)):
            print(f"  {finding}", file=sys.stderr)
        return 1
    scope = "current tree" if args.current_only else "current tree and reachable Git history"
    print(f"PASS: no unreviewed configured sensitive patterns found in {scope}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
