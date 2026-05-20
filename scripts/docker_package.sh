#!/usr/bin/env bash
set -euxo pipefail

EXTENSIONS_DIR=/build/extensions
POSTGIS_DIR=${EXTENSIONS_DIR}/postgis
POSTGIS_INSTALL_DIR=${POSTGIS_INSTALL_DIR:-/build/postgis_install}

mkdir -p "${POSTGIS_DIR}/lib/postgresql"
mkdir -p "${POSTGIS_DIR}/share/proj"
mkdir -p "${POSTGIS_DIR}/share/postgresql/extension"

if [ -d "${POSTGIS_INSTALL_DIR}/lib" ]; then
  cp -v "${POSTGIS_INSTALL_DIR}"/lib/*.so "${POSTGIS_DIR}/lib/postgresql/"
fi

for so in "${POSTGIS_DIR}"/lib/postgresql/*.so; do
  [ -f "${so}" ] || continue

  stripped="${so}.stripped"
  echo "Stripping WASM EH from ${so}"
  wasm-opt --strip-eh \
    --all-features \
    --no-validation \
    "${so}" -o "${stripped}"
  mv "${stripped}" "${so}"
done

for control in "${POSTGIS_INSTALL_DIR}"/*.control; do
  [ -f "${control}" ] && cp -v "${control}" "${POSTGIS_DIR}/share/postgresql/extension/"
done

for sql in "${POSTGIS_INSTALL_DIR}"/*.sql; do
  [ -f "${sql}" ] && cp -v "${sql}" "${POSTGIS_DIR}/share/postgresql/extension/"
done

if [ -d /opt/wasix/share/proj ]; then
  cp -av /opt/wasix/share/proj/. "${POSTGIS_DIR}/share/proj/"
fi

cat > "${POSTGIS_DIR}/share/postgresql/extension/postgis.control" << 'EOF'
comment = 'PostGIS geometry and geography spatial types and functions'
default_version = '3.5.2'
module_pathname = '$libdir/postgis-3'
relocatable = false
schema = public
EOF

cat > "${POSTGIS_DIR}/catalog.toml" << 'EOF'
[extension]
name = "postgis"
version = "3.5.2"
promotion = "stable"

[[load_order]]
so = "postgis-3.so"

[[load_order]]
so = "postgis_topology-3.so"
optional = true
EOF

echo "PostGIS files staged at ${POSTGIS_DIR}"

cd "${EXTENSIONS_DIR}"
tar -cf - -C postgis lib share catalog.toml | zstd -T0 -o postgis.tar.zst

echo "Package created: ${EXTENSIONS_DIR}/postgis.tar.zst"
ls -lh "${EXTENSIONS_DIR}/postgis.tar.zst"
