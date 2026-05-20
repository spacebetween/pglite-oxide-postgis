#!/usr/bin/env bash
# Package the host-built pglited-oxide binary as a GitHub release asset.
#
# Usage:
#   scripts/package_pglited_oxide.sh [target-triple] [binary-path] [output-dir]
#
# Output:
#   release-assets/pglited-oxide-<target-triple>.tar.gz
#   release-assets/pglited-oxide-<target-triple>.tar.gz.sha256
set -euo pipefail

detect_target() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"

  case "${os}-${arch}" in
    Darwin-arm64) echo "aarch64-apple-darwin" ;;
    Linux-x86_64) echo "x86_64-unknown-linux-gnu" ;;
    Linux-aarch64) echo "aarch64-unknown-linux-gnu" ;;
    *)
      echo "error: unsupported platform ${os}-${arch}" >&2
      exit 1
      ;;
  esac
}

TARGET_TRIPLE="${1:-$(detect_target)}"
BINARY="${2:-pglited-oxide/target/release/pglited-oxide}"
OUT_DIR="${3:-release-assets}"
ASSET="pglited-oxide-${TARGET_TRIPLE}.tar.gz"

if [[ ! -x "${BINARY}" ]]; then
  echo "error: binary not found or not executable: ${BINARY}" >&2
  exit 1
fi

mkdir -p "${OUT_DIR}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

cp "${BINARY}" "${WORK_DIR}/pglited-oxide"
chmod 755 "${WORK_DIR}/pglited-oxide"

tar -czf "${OUT_DIR}/${ASSET}" -C "${WORK_DIR}" pglited-oxide

if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "${OUT_DIR}/${ASSET}" | awk '{print $1 "  " "'${ASSET}'"}' > "${OUT_DIR}/${ASSET}.sha256"
else
  shasum -a 256 "${OUT_DIR}/${ASSET}" | awk '{print $1 "  " "'${ASSET}'"}' > "${OUT_DIR}/${ASSET}.sha256"
fi

echo "packaged ${OUT_DIR}/${ASSET}"
cat "${OUT_DIR}/${ASSET}.sha256"
