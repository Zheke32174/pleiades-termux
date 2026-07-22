#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${1:-$ROOT/dist}"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
MANIFEST="$ROOT/release/source-files.txt"

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

[[ -f "$MANIFEST" ]] || {
  echo "reviewed source manifest missing: $MANIFEST" >&2
  exit 2
}
mapfile -t SOURCE_FILES < <(sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$MANIFEST")
[[ ${#SOURCE_FILES[@]} -gt 0 ]] || {
  echo "reviewed source manifest is empty" >&2
  exit 2
}
[[ "$(printf '%s\n' "${SOURCE_FILES[@]}" | LC_ALL=C sort -u)" == "$(printf '%s\n' "${SOURCE_FILES[@]}")" ]] || {
  echo "reviewed source manifest must be sorted and unique" >&2
  exit 2
}

COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$ROOT" show -s --format=%ct "$COMMIT")}" 
NAME="pleiades-termux-$VERSION"
ARCHIVE="$OUT_DIR/$NAME.tar.gz"
SBOM="$OUT_DIR/$NAME.spdx.json"
RECEIPT="$OUT_DIR/$NAME.build-receipt.json"
MANIFEST_SHA256="$(sha256sum "$MANIFEST" | awk '{print $1}')"

for path in "${SOURCE_FILES[@]}"; do
  git -C "$ROOT" cat-file -e "$COMMIT:$path" || {
    echo "source manifest path missing from reviewed commit: $path" >&2
    exit 2
  }
done

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

git -C "$ROOT" archive --format=tar --prefix="$NAME/" "$COMMIT" -- "${SOURCE_FILES[@]}" | gzip -n > "$ARCHIVE"
python3 "$ROOT/scripts/write_spdx_sbom.py" "$SBOM" --version "$VERSION" --manifest "$MANIFEST"

ARCHIVE_SHA256="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
SBOM_SHA256="$(sha256sum "$SBOM" | awk '{print $1}')"
SOURCE_FILE_COUNT="${#SOURCE_FILES[@]}"
export VERSION COMMIT SOURCE_DATE_EPOCH ARCHIVE SBOM ARCHIVE_SHA256 SBOM_SHA256 RECEIPT MANIFEST_SHA256 SOURCE_FILE_COUNT
python3 - <<'PY'
import datetime as dt
import json
import os
from pathlib import Path

created = dt.datetime.fromtimestamp(int(os.environ["SOURCE_DATE_EPOCH"]), tz=dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
receipt = {
    "schema": "pleiades.termux.source-release/v2",
    "repository": "Zheke32174/pleiades-termux",
    "version": os.environ["VERSION"],
    "commit": os.environ["COMMIT"],
    "source_date_epoch": int(os.environ["SOURCE_DATE_EPOCH"]),
    "created_from_commit_time": created,
    "release_manifest": {
        "name": "release/source-files.txt",
        "sha256": os.environ["MANIFEST_SHA256"],
        "file_count": int(os.environ["SOURCE_FILE_COUNT"]),
    },
    "archive": {"name": Path(os.environ["ARCHIVE"]).name, "sha256": os.environ["ARCHIVE_SHA256"]},
    "sbom": {"name": Path(os.environ["SBOM"]).name, "sha256": os.environ["SBOM_SHA256"], "format": "SPDX-2.3 JSON"},
    "contains_quarantined_legacy_scripts": False,
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
