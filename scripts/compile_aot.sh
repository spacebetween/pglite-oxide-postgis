#!/usr/bin/env bash
# Compile PostGIS WASM .so files to native AOT artifacts for the current host platform.
# Downloads wasmer 7.2.0-alpha.2 to a local cache the first time; does not require
# system-wide installation.
#
# Usage:
#   ./scripts/compile_aot.sh [path/to/postgis.tar.zst]
#
# Output:
#   aot-artifacts/<triple>/postgis-3-llvm-opta.bin.zst
#   aot-artifacts/<triple>/postgis_topology-3-llvm-opta.bin.zst
#   aot-artifacts/<triple>/manifest.json
set -euo pipefail

ARCHIVE="${1:-dist/postgis.tar.zst}"
WASMER_VERSION="7.2.0-alpha.2"
BINARYEN_VERSION="version_129"
TOOL_CACHE="${HOME}/.cache/pglite-oxide-postgis"
WASMER_CACHE_DIR="${TOOL_CACHE}/wasmer-${WASMER_VERSION}"
WASMER_BIN="${WASMER_CACHE_DIR}/bin/wasmer"
WASM_OPT_BIN="${TOOL_CACHE}/binaryen-${BINARYEN_VERSION}/bin/wasm-opt"

# ── Platform detection ────────────────────────────────────────────────────────
OS=$(uname -s)
ARCH=$(uname -m)

case "${OS}-${ARCH}" in
  Darwin-arm64)
    TARGET_TRIPLE="aarch64-apple-darwin"
    WASMER_ASSET="wasmer-darwin-arm64.tar.gz"
    BINARYEN_ASSET="binaryen-${BINARYEN_VERSION}-arm64-macos.tar.gz"
    ;;
  Linux-aarch64)
    TARGET_TRIPLE="aarch64-unknown-linux-gnu"
    WASMER_ASSET="wasmer-linux-aarch64.tar.gz"
    BINARYEN_ASSET="binaryen-${BINARYEN_VERSION}-aarch64-linux.tar.gz"
    ;;
  Linux-x86_64)
    TARGET_TRIPLE="x86_64-unknown-linux-gnu"
    WASMER_ASSET="wasmer-linux-amd64.tar.gz"
    BINARYEN_ASSET="binaryen-${BINARYEN_VERSION}-x86_64-linux.tar.gz"
    ;;
  Darwin-x86_64)
    echo "error: no pre-built wasmer ${WASMER_VERSION} for macOS x86_64." >&2
    echo "       Run under Rosetta 2 (arch -arm64 bash $0) or build wasmer from source." >&2
    exit 1
    ;;
  *)
    echo "error: unsupported platform ${OS}-${ARCH}" >&2
    exit 1
    ;;
esac

# ── Install wasmer if not cached ──────────────────────────────────────────────
if ! "${WASMER_BIN}" --version 2>/dev/null | grep -qF "${WASMER_VERSION}"; then
    echo "==> Downloading wasmer ${WASMER_VERSION} (${WASMER_ASSET})..."
    mkdir -p "${WASMER_CACHE_DIR}"
    curl -fsSL \
      "https://github.com/wasmerio/wasmer/releases/download/v${WASMER_VERSION}/${WASMER_ASSET}" \
      | tar -xz -C "${WASMER_CACHE_DIR}"
    echo "==> wasmer cached at ${WASMER_BIN}"
fi

echo "==> $(${WASMER_BIN} --version)"

# Confirm LLVM backend is present
if ! "${WASMER_BIN}" compile --help 2>&1 | grep -qi "llvm"; then
    echo "error: the wasmer binary at ${WASMER_BIN} has no LLVM backend." >&2
    echo "       Build from source: cargo install wasmer-cli --features llvm" >&2
    exit 1
fi

# ── Install wasm-opt (Binaryen) if not cached ─────────────────────────────────
BINARYEN_CACHE_DIR="${TOOL_CACHE}/binaryen-${BINARYEN_VERSION}"
WASM_OPT_BIN="${BINARYEN_CACHE_DIR}/bin/wasm-opt"

# Prefer system wasm-opt if it is already the right version
_SYSTEM_OPT=$(command -v wasm-opt 2>/dev/null || true)
if [[ -n "${_SYSTEM_OPT}" ]] && "${_SYSTEM_OPT}" --version 2>&1 | grep -qF "${BINARYEN_VERSION#version_}"; then
    WASM_OPT_BIN="${_SYSTEM_OPT}"
    echo "==> Using system wasm-opt: ${WASM_OPT_BIN}"
elif ! "${WASM_OPT_BIN}" --version 2>/dev/null | grep -qF "${BINARYEN_VERSION#version_}"; then
    echo "==> Downloading Binaryen ${BINARYEN_VERSION} (${BINARYEN_ASSET})..."
    mkdir -p "${BINARYEN_CACHE_DIR}"
    curl -fsSL \
      "https://github.com/WebAssembly/binaryen/releases/download/${BINARYEN_VERSION}/${BINARYEN_ASSET}" \
      | tar -xz --strip-components=1 -C "${BINARYEN_CACHE_DIR}"
    echo "==> wasm-opt installed at ${WASM_OPT_BIN}"
fi

echo "==> wasm-opt $("${WASM_OPT_BIN}" --version)"

# ── Validate archive ──────────────────────────────────────────────────────────
if [[ ! -f "${ARCHIVE}" ]]; then
    echo "error: archive not found: ${ARCHIVE}" >&2
    echo "       Run the Docker build first: ./scripts/build.sh" >&2
    exit 1
fi

# ── Seed AOT_DIR with existing platform artifacts from cargo registry ─────────
AOT_DIR="aot-artifacts/${TARGET_TRIPLE}"
mkdir -p "${AOT_DIR}"

# The PGLITE_OXIDE_GENERATED_AOT_DIR mechanism replaces the entire artifact set
# for the target platform.  We must copy the existing runtime/extension artifacts
# from the published crate so the headless engine can still find runtime:pglite,
# initdb, plpgsql, etc.
CARGO_HOME="${CARGO_HOME:-${HOME}/.cargo}"
CRATE_ARTIFACTS=$(find "${CARGO_HOME}/registry/src" \
    -path "*/pglite-oxide-aot-${TARGET_TRIPLE}-*/artifacts" -type d 2>/dev/null | head -1)

if [[ -z "${CRATE_ARTIFACTS}" ]]; then
    echo "warning: could not find pglite-oxide-aot-${TARGET_TRIPLE} in cargo registry." >&2
    echo "         Run 'cargo fetch' inside tests/postgis-smoke first, then re-run this script." >&2
    echo "         Continuing with PostGIS-only artifacts (smoke test will fail at db open)." >&2
    EXISTING_MANIFEST=""
else
    echo "==> Copying existing platform artifacts from ${CRATE_ARTIFACTS}"
    # Copy all .bin.zst files but skip any existing PostGIS entries (we will replace them)
    for f in "${CRATE_ARTIFACTS}"/*.bin.zst; do
        base=$(basename "${f}")
        # Skip postgis artifacts if they already exist — we'll overwrite with fresh ones
        case "${base}" in
            postgis-3-*|postgis_topology-3-*) continue ;;
        esac
        cp -f "${f}" "${AOT_DIR}/"
    done
    EXISTING_MANIFEST="${CRATE_ARTIFACTS}/manifest.json"
fi

# ── Extract .so files ─────────────────────────────────────────────────────────
WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT

echo "==> Extracting .so files from ${ARCHIVE}"
tar -xf "${ARCHIVE}" -C "${WORK_DIR}" \
    lib/postgresql/postgis-3.so \
    lib/postgresql/postgis_topology-3.so

# ── Compile + compress ────────────────────────────────────────────────────────
compile_artifact() {
    local so_name="$1"
    local stem="${so_name%.so}"
    local so_path="${WORK_DIR}/lib/postgresql/${so_name}"
    local stripped_path="${WORK_DIR}/${stem}-noeh.wasm"
    local bin_path="${WORK_DIR}/${stem}-llvm-opta.bin"
    local zst_path="${AOT_DIR}/${stem}-llvm-opta.bin.zst"

    # Strip WASM exception instructions before AOT compile.
    # PostGIS uses GEOS (C++) which emits legacy_exceptions; wasmer 7.2.0-alpha.2's
    # LLVM/Cranelift backends cannot compile them without this step.
    echo "==> wasm-opt --strip-eh ${so_name}"
    "${WASM_OPT_BIN}" --strip-eh \
      --all-features \
      --no-validation \
      "${so_path}" -o "${stripped_path}"

    echo "==> wasmer compile --llvm ${stem}"
    "${WASMER_BIN}" compile --llvm "${stripped_path}" -o "${bin_path}"
    echo "==> zstd -19 → ${zst_path}"
    zstd -19 -f "${bin_path}" -o "${zst_path}"
}

compile_artifact "postgis-3.so"
compile_artifact "postgis_topology-3.so"

# ── Compute hashes for new artifacts ─────────────────────────────────────────
sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

raw_size() {
    if [[ "${OS}" == "Darwin" ]]; then
        stat -f %z "$1"
    else
        stat -c %s "$1"
    fi
}

postgis_artifact_json() {
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

    python3 -c "
import json
print(json.dumps({
    'name': 'extension:${stem}',
    'path': '${zst_name}',
    'sha256': '${zst_sha256}',
    'raw-sha256': '${raw_sha256}',
    'raw-size': ${size},
    'module-sha256': '${module_sha256}',
    'compressed': True,
}, indent=4))"
}

# ── Merge manifests and write final manifest.json ─────────────────────────────
echo "==> Computing hashes and writing manifest.json"

NEW_A1=$(postgis_artifact_json "postgis-3.so")
NEW_A2=$(postgis_artifact_json "postgis_topology-3.so")

python3 - "${AOT_DIR}/manifest.json" "${EXISTING_MANIFEST:-}" <<PYEOF
import json, sys, os

# new_artifacts are JSON strings (from json.dumps) — parse them, not eval them
new_artifacts = [
    json.loads("""${NEW_A1}"""),
    json.loads("""${NEW_A2}"""),
]
new_names = {a['name'] for a in new_artifacts}

out_path  = sys.argv[1]
base_path = sys.argv[2] if len(sys.argv) > 2 else ""

if base_path and os.path.isfile(base_path):
    with open(base_path) as f:
        manifest = json.load(f)
    manifest['artifacts'] = [a for a in manifest['artifacts'] if a['name'] not in new_names]
    manifest['artifacts'].extend(new_artifacts)
else:
    manifest = {
        "format-version": 1,
        "target-triple": "${TARGET_TRIPLE}",
        "engine": "llvm-opta",
        "wasmer-version": "${WASMER_VERSION}",
        "wasmer-wasix-version": "0.702.0-alpha.2",
        "artifacts": new_artifacts,
    }

with open(out_path, 'w') as f:
    json.dump(manifest, f, indent=2)
    f.write('\n')

print(f"Manifest written: {len(manifest['artifacts'])} artifacts")
PYEOF

echo
echo "==> AOT artifacts written to ${AOT_DIR}/"
ls -lh "${AOT_DIR}/"
