#!/usr/bin/env bash
set -euo pipefail

: "${SELECTED_REF:?SELECTED_REF is required}"
: "${DEFAULT_BRANCH:?DEFAULT_BRANCH is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

if [[ "${SELECTED_REF}" != "${DEFAULT_BRANCH}" ]]; then
  echo "error: Release 只能从默认分支 ${DEFAULT_BRANCH} 运行，当前为 ${SELECTED_REF}" >&2
  exit 1
fi

python3 <<'PY'
import os
import plistlib
import re

with open("Info.plist", "rb") as plist_file:
    plist = plistlib.load(plist_file)

version = plist.get("CFBundleShortVersionString")
build_number = str(plist.get("CFBundleVersion", ""))

if (
    not isinstance(version, str)
    or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version)
):
    raise SystemExit(
        "error: CFBundleShortVersionString 必须使用 MAJOR.MINOR.PATCH 格式"
    )

if not re.fullmatch(r"[0-9]+", build_number):
    raise SystemExit("error: CFBundleVersion 必须是整数")

release_tag = f"v{version}"

with open(
    os.environ["GITHUB_OUTPUT"],
    "a",
    encoding="utf-8",
) as output:
    output.write(f"release_tag={release_tag}\n")

print(f"Release tag: {release_tag} (build {build_number})")
PY
