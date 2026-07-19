#!/usr/bin/env python3
"""Write a deterministic SPDX 2.3 JSON inventory for the exact Git commit."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import pathlib
import re
import subprocess


def git(root: pathlib.Path, *args: str, text: bool = True) -> str | bytes:
    result = subprocess.run(["git", *args], cwd=root, check=False, capture_output=True, text=text)
    if result.returncode != 0:
        detail = result.stderr if text else result.stderr.decode("utf-8", errors="replace")
        raise SystemExit(f"git {' '.join(args)} failed: {detail.strip()}")
    return result.stdout


def spdx_id(path: str) -> str:
    return f"SPDXRef-File-{hashlib.sha256(path.encode('utf-8')).hexdigest()[:24]}"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=pathlib.Path)
    parser.add_argument("--version", required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?", args.version):
        raise SystemExit("version must be semantic-version shaped")

    root = pathlib.Path(__file__).resolve().parents[1]
    commit = str(git(root, "rev-parse", "HEAD")).strip()
    epoch = int(str(git(root, "show", "-s", "--format=%ct", commit)).strip())
    created = dt.datetime.fromtimestamp(epoch, tz=dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    paths = sorted(line for line in str(git(root, "ls-files")).splitlines() if line)

    files = []
    relationships = [{"spdxElementId": "SPDXRef-DOCUMENT", "relationshipType": "DESCRIBES", "relatedSpdxElement": "SPDXRef-Package"}]
    for path in paths:
        content = bytes(git(root, "show", f"{commit}:{path}", text=False))
        file_id = spdx_id(path)
        files.append({
            "fileName": f"./{path}",
            "SPDXID": file_id,
            "checksums": [{"algorithm": "SHA256", "checksumValue": hashlib.sha256(content).hexdigest()}],
            "licenseConcluded": "NOASSERTION",
            "copyrightText": "NOASSERTION",
        })
        relationships.append({"spdxElementId": "SPDXRef-Package", "relationshipType": "CONTAINS", "relatedSpdxElement": file_id})

    document = {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": f"pleiades-termux-{args.version}",
        "documentNamespace": f"https://github.com/Zheke32174/pleiades-termux/sbom/{commit}",
        "creationInfo": {"created": created, "creators": ["Tool: scripts/write_spdx_sbom.py"]},
        "packages": [{
            "name": "pleiades-termux",
            "SPDXID": "SPDXRef-Package",
            "versionInfo": args.version,
            "downloadLocation": "NOASSERTION",
            "filesAnalyzed": True,
            "licenseConcluded": "MIT",
            "licenseDeclared": "MIT",
            "copyrightText": "Copyright (c) 2026 Pleiades Contributors",
            "externalRefs": [{
                "referenceCategory": "PACKAGE-MANAGER",
                "referenceType": "purl",
                "referenceLocator": f"pkg:github/Zheke32174/pleiades-termux@{commit}",
            }],
        }],
        "files": files,
        "relationships": relationships,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
