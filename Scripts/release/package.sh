#!/usr/bin/env bash
set -euo pipefail

: "${RELEASE_TAG:?RELEASE_TAG is required}"
: "${TARGET_ARCH:?TARGET_ARCH is required}"

mkdir -p dist

archive_name="MicLock-${RELEASE_TAG}-${TARGET_ARCH}.zip"
archive_path="dist/${archive_name}"
checksum_path="${archive_path}.sha256"

ditto \
  -c \
  -k \
  --sequesterRsrc \
  --keepParent \
  build/MicLock.app \
  "${archive_path}"

(
  cd dist
  shasum -a 256 "${archive_name}" > "${archive_name}.sha256"

  # 在上传 artifact 前立即验证一次。
  shasum -a 256 -c "${archive_name}.sha256"
)

echo "Release assets:"
ls -lh dist/

echo
echo "SHA256:"
cat "${checksum_path}"
