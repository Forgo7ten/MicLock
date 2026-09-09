#!/usr/bin/env bash
set -euo pipefail

: "${RELEASE_TAG:?RELEASE_TAG is required}"

cd dist

arm_archive="MicLock-${RELEASE_TAG}-arm64.zip"
intel_archive="MicLock-${RELEASE_TAG}-x86_64.zip"

expected_files=(
  "${arm_archive}"
  "${arm_archive}.sha256"
  "${intel_archive}"
  "${intel_archive}.sha256"
)

for file in "${expected_files[@]}"; do
  if [[ ! -s "${file}" ]]; then
    echo "error: Missing or empty release asset: ${file}" >&2
    exit 1
  fi
done

sha256sum --check "${arm_archive}.sha256"
sha256sum --check "${intel_archive}.sha256"

echo "Verified release assets:"
ls -lh
