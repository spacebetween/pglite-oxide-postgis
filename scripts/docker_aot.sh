#!/usr/bin/env bash
# Runs inside the aot-compile Docker stage.
# Compiles postgis-3.so and postgis_topology-3.so to native AOT using wasmer --llvm,
# then writes compressed artifacts and manifest.json to /build/aot/<triple>/.
set -euxo pipefail

EXTENSIONS_DIR=/build/extensions
WORK_DIR=/tmp/aot-work
ARCHIVE="${EXTENSIONS_DIR}/postgis.tar.zst"

ARCH=$(uname -m)
case "$ARCH" in
  aarch64) TARGET_TRIPLE="aarch64-unknown-linux-gnu" ;;
  x86_64)  TARGET_TRIPLE="x86_64-unknown-linux-gnu" ;;
  *)       echo "Unsupported arch: $ARCH"; exit 1 ;;
esac

AOT_DIR="/build/aot/${TARGET_TRIPLE}"
mkdir -p "${WORK_DIR}/lib/postgresql" "${AOT_DIR}"

echo "==> Extracting .so files from archive"
tar -xf "${ARCHIVE}" -C "${WORK_DIR}" \
    lib/postgresql/postgis-3.so \
    lib/postgresql/postgis_topology-3.so

compile_artifact() {
    local so_name="$1"
    local stem="${so_name%.so}"
    local so_path="${WORK_DIR}/lib/postgresql/${so_name}"
    local stripped_path="${WORK_DIR}/${stem}-noeh.wasm"
    local bin_path="${WORK_DIR}/${stem}-llvm-opta.bin"
    local zst_path="${AOT_DIR}/${stem}-llvm-opta.bin.zst"

    # Strip WASM exception instructions (try/catch/throw become unreachable).
    # PostGIS uses GEOS which emits legacy_exceptions; wasmer 7.2.0-alpha.2's
    # LLVM/Cranelift backends cannot compile them, so we strip before AOT compile.
    echo "==> wasm-opt --strip-eh ${so_name}"
    wasm-opt --strip-eh \
      --all-features \
      --no-validation \
      "${so_path}" -o "${stripped_path}"

    echo "==> wasmer compile --llvm ${stem}"
    wasmer compile --llvm "${stripped_path}" -o "${bin_path}"
    echo "==> zstd -19 → ${zst_path}"
    zstd -19 "${bin_path}" -o "${zst_path}"
}

compile_artifact "postgis-3.so"
compile_artifact "postgis_topology-3.so"

echo "==> Computing hashes and writing manifest.json"

sha256() { sha256sum "$1" | awk '{print $1}'; }
raw_size() { stat -c %s "$1"; }

artifact_json() {
    local so_name="$1"
    local stem="${so_name%.so}"
    local so_path="${WORK_DIR}/lib/postgresql/${so_name}"
    local bin_path="${WORK_DIR}/${stem}-llvm-opta.bin"
    local zst_name="${stem}-llvm-opta.bin.zst"
    local zst_path="${AOT_DIR}/${zst_name}"

    local module_sha256; module_sha256=$(sha256 "${so_path}")
    local raw_sha256;    raw_sha256=$(sha256 "${bin_path}")
    local zst_sha256;    zst_sha256=$(sha256 "${zst_path}")
    local size;          size=$(raw_size "${bin_path}")

    printf '    {\n'
    printf '      "name": "extension:%s",\n' "${stem}"
    printf '      "path": "%s",\n'            "${zst_name}"
    printf '      "sha256": "%s",\n'          "${zst_sha256}"
    printf '      "raw-sha256": "%s",\n'      "${raw_sha256}"
    printf '      "raw-size": %d,\n'          "${size}"
    printf '      "module-sha256": "%s",\n'   "${module_sha256}"
    printf '      "compressed": true\n'
    printf '    }'
}

A1=$(artifact_json "postgis-3.so")
A2=$(artifact_json "postgis_topology-3.so")

cat > "${AOT_DIR}/manifest.json" <<EOF
{
  "format-version": 1,
  "target-triple": "${TARGET_TRIPLE}",
  "engine": "llvm-opta",
  "wasmer-version": "7.2.0-alpha.2",
  "wasmer-wasix-version": "0.702.0-alpha.2",
  "artifacts": [
${A1},
${A2}
  ]
}
EOF

echo "==> AOT artifacts:"
ls -lh "${AOT_DIR}/"
