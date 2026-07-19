#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${1:-$ROOT/dist}"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]] || {
  echo "invalid VERSION: $VERSION" >&2
  exit 2
}

for command in git gzip python3 sha256sum; do
  command -v "$command" >/dev/null || {
    echo "missing required command: $command" >&2
    exit 2
  }
done

if [[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ]]; then
  echo "tracked working tree is dirty; package only an exact reviewed commit" >&2
  exit 2
fi

COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$ROOT" show -s --format=%ct "$COMMIT")}" 
NAME="pleiades-termux-$VERSION"
ARCHIVE="$OUT_DIR/$NAME.tar.gz"
SBOM="$OUT_DIR/$NAME.spdx.json"
RECEIPT="$OUT_DIR/$NAME.build-receipt.json"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

git -C "$ROOT" archive --format=tar --prefix="$NAME/" "$COMMIT" | gzip -n > "$ARCHIVE"
python3 "$ROOT/scripts/write_spdx_sbom.py" "$SBOM" --version "$VERSION"

ARCHIVE_SHA256="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
SBOM_SHA256="$(sha256sum "$SBOM" | awk '{print $1}')"
export VERSION COMMIT SOURCE_DATE_EPOCH ARCHIVE SBOM ARCHIVE_SHA256 SBOM_SHA256 RECEIPT
python3 - <<'PY'
import datetime as dt
import json
import os
from pathlib import Path

created = dt.datetime.fromtimestamp(int(os.environ["SOURCE_DATE_EPOCH"]), tz=dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
receipt = {
    "schema": "pleiades.termux.source-release/v1",
    "repository": "Zheke32174/pleiades-termux",
    "version": os.environ["VERSION"],
    "commit": os.environ["COMMIT"],
    "source_date_epoch": int(os.environ["SOURCE_DATE_EPOCH"]),
    "created_from_commit_time": created,
    "archive": {"name": Path(os.environ["ARCHIVE"]).name, "sha256": os.environ["ARCHIVE_SHA256"]},
    "sbom": {"name": Path(os.environ["SBOM"]).name, "sha256": os.environ["SBOM_SHA256"], "format": "SPDX-2.3 JSON"},
    "contains_runtime_state": False,
    "contains_credentials": False,
    "contains_android_apk": False,
    "contains_container_image": False,
    "authority": "observation-only local edge source and install helpers",
}
Path(os.environ["RECEIPT"]).write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

(
  cd "$OUT_DIR"
  sha256sum "$(basename "$ARCHIVE")" "$(basename "$SBOM")" "$(basename "$RECEIPT")" > SHA256SUMS.txt
)

echo "PACKAGE $ARCHIVE"
echo "SBOM $SBOM"
echo "RECEIPT $RECEIPT"
