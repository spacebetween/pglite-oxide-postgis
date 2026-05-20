#!/usr/bin/env bash
set -euxo pipefail

POSTGIS_VERSION=${POSTGIS_VERSION:-3.5.2}
POSTGIS_SRC_DIR=/build/postgis-${POSTGIS_VERSION}
POSTGIS_INSTALL_DIR=/build/postgis_install

if [ -d "${POSTGIS_SRC_DIR}" ]; then
  echo "PostGIS source already at ${POSTGIS_SRC_DIR}"
else
  curl -fsSL "https://download.osgeo.org/postgis/source/postgis-${POSTGIS_VERSION}.tar.gz" \
    | tar -xz -C /build
fi

cd "${POSTGIS_SRC_DIR}"

if [ -f ./autogen.sh ]; then
  ./autogen.sh
elif [ -f ./autoconf.sh ]; then
  ./autoconf.sh
fi

# PROJ itself works under WASIX once proj.db is packaged and PROJ_DATA points at
# it, including CRS lookup and ST_Transform. PostGIS 3.5's version function also
# calls optional PROJ diagnostic getters for network/user-writable/database
# paths; under this WASIX runtime those probes can abort/throw even though the
# actual PROJ operations are usable. Keep the SQL-visible version function to
# the compile-time PROJ version macro so postgis_full_version() does not trip
# the diagnostics path.
patch -p0 <<'PATCH'
--- postgis/lwgeom_transform.c
+++ postgis/lwgeom_transform.c
@@ -205,26 +205,12 @@ Datum postgis_proj_version(PG_FUNCTION_ARGS)
 {
 	stringbuffer_t sb;
 
-	PJ_INFO pji = proj_info();
 	stringbuffer_init(&sb);
-	stringbuffer_append(&sb, pji.version);
+	stringbuffer_aprintf(&sb,
+		"%d.%d.%d",
+		(POSTGIS_PROJ_VERSION/10000),
+		((POSTGIS_PROJ_VERSION%10000)/100),
+		((POSTGIS_PROJ_VERSION)%100));
 
-#if POSTGIS_PROJ_VERSION >= 70100
-
-	stringbuffer_aprintf(&sb,
-		" NETWORK_ENABLED=%s",
-		proj_context_is_network_enabled(NULL) ? "ON" : "OFF");
-
-	if (proj_context_get_url_endpoint(NULL))
-		stringbuffer_aprintf(&sb, " URL_ENDPOINT=%s", proj_context_get_url_endpoint(NULL));
-
-	if (proj_context_get_user_writable_directory(NULL, 0))
-		stringbuffer_aprintf(&sb, " USER_WRITABLE_DIRECTORY=%s", proj_context_get_user_writable_directory(NULL, 0));
-
-	if (proj_context_get_database_path(NULL))
-		stringbuffer_aprintf(&sb, " DATABASE_PATH=%s", proj_context_get_database_path(NULL));
-
-#endif
-
 	PG_RETURN_POINTER(cstring_to_text(stringbuffer_getstring(&sb)));
 }
 
PATCH

python3 - <<'PY'
from pathlib import Path

path = Path("postgis/postgis.sql.in")
text = path.read_text()
old = """\tBEGIN
\t\tSELECT @extschema@.postgis_gdal_version() INTO gdalver;
\tEXCEPTION
\t\tWHEN undefined_function THEN
\t\t\tRAISE DEBUG 'Function postgis_gdal_version() not found.  Is raster support enabled and rtpostgis.sql installed?';
\tEND;
\tBEGIN
\t\tSELECT @extschema@.postgis_sfcgal_full_version() INTO sfcgalver;
\t\tBEGIN
\t\t\tSELECT @extschema@.postgis_sfcgal_scripts_installed() INTO sfcgal_scr_ver;
\t\tEXCEPTION
\t\t\tWHEN undefined_function THEN
\t\t\t\tsfcgal_scr_ver := 'missing';
\t\tEND;
\tEXCEPTION
\t\tWHEN undefined_function THEN
\t\t\tRAISE DEBUG 'Function postgis_sfcgal_scripts_installed() not found. Is sfcgal support enabled and sfcgal.sql installed?';
\tEND;
"""
if old not in text:
    raise SystemExit("expected optional GDAL/SFCGAL probe block not found")
text = text.replace(old, "", 1)
old = """\tBEGIN
\t\tSELECT topology.postgis_topology_scripts_installed() INTO topo_scr_ver;
\tEXCEPTION
\t\tWHEN undefined_function OR invalid_schema_name THEN
\t\t\tRAISE DEBUG 'Function postgis_topology_scripts_installed() not found. Is topology support enabled and topology.sql installed?';
\t\tWHEN insufficient_privilege THEN
\t\t\tRAISE NOTICE 'Topology support cannot be inspected. Is current user granted USAGE on schema \"topology\" ?';
\t\tWHEN OTHERS THEN
\t\t\tRAISE NOTICE 'Function postgis_topology_scripts_installed() could not be called: % (%)', SQLERRM, SQLSTATE;
\tEND;

\tBEGIN
\t\tSELECT postgis_raster_scripts_installed() INTO rast_scr_ver;
\tEXCEPTION
\t\tWHEN undefined_function THEN
\t\t\tRAISE DEBUG 'Function postgis_raster_scripts_installed() not found. Is raster support enabled and rtpostgis.sql installed?';
\t\tWHEN OTHERS THEN
\t\t\tRAISE NOTICE 'Function postgis_raster_scripts_installed() could not be called: % (%)', SQLERRM, SQLSTATE;
\tEND;

\tBEGIN
\t\tSELECT @extschema@.postgis_raster_lib_version() INTO rast_lib_ver;
\tEXCEPTION
\t\tWHEN undefined_function THEN
\t\t\tRAISE DEBUG 'Function postgis_raster_lib_version() not found. Is raster support enabled and rtpostgis.sql installed?';
\t\tWHEN OTHERS THEN
\t\t\tRAISE NOTICE 'Function postgis_raster_lib_version() could not be called: % (%)', SQLERRM, SQLSTATE;
\tEND;

"""
if old not in text:
    raise SystemExit("expected optional topology/raster probe block not found")
text = text.replace(old, "", 1)
path.write_text(text)
PY

export CC=wasixcc
export CXX=wasixc++
export AR="llvm-ar"
export RANLIB="llvm-ranlib"
export STRIP="llvm-strip"

CFLAGS="--target=${WASIX_TARGET} --sysroot=${WASIX_SYSROOT} -O1 -fno-vectorize -fno-slp-vectorize -matomics -mbulk-memory -mmutable-globals -I${PG_INSTALL_DIR}/include -I${PG_INSTALL_DIR}/include/server -I${PG_INSTALL_DIR}/include/libpq"
CXXFLAGS="--target=${WASIX_TARGET} --sysroot=${WASIX_SYSROOT} -O1 -fno-vectorize -fno-slp-vectorize -fwasm-exceptions -matomics -mbulk-memory -mmutable-globals -I${PG_INSTALL_DIR}/include -I${PG_INSTALL_DIR}/include/server -I${PG_INSTALL_DIR}/include/libpq"
LDFLAGS="-L${PG_INSTALL_DIR}/lib -Wl,--allow-undefined"

export PROJ_DIR=${WASIX_PREFIX}
export GEOS_DIR=${WASIX_PREFIX}
export JSON_DIR=${WASIX_PREFIX}
export XML2_DIR=${WASIX_PREFIX}
export SQLITE3_DIR=${WASIX_PREFIX}

GEOSCONFIG="${WASIX_PREFIX}/bin/geos-config"
if [ -f "${GEOSCONFIG}" ]; then
  export GEOSCONFIG
  chmod +x "${GEOSCONFIG}"
fi

PG_CONFIG="${PG_INSTALL_DIR}/bin/pg_config"
export PG_CONFIG

# autoconf AC_PROG_CXX with --host=wasm32-wasi searches for wasm32-wasi-g++
# before respecting $CXX. Create symlinks so it finds our WASIX wrappers.
ln -sf /usr/local/bin/wasixc++ /usr/local/bin/wasm32-wasi-g++
ln -sf /usr/local/bin/wasixcc  /usr/local/bin/wasm32-wasi-gcc

# Ensure libpq-fe.h is at pg_config --includedir (not just in the libpq/ subdir).
mkdir -p "${PG_INSTALL_DIR}/include/libpq"
for src in "${PG_INSTALL_DIR}/include/libpq/libpq-fe.h" \
           /build/postgresql-*/src/interfaces/libpq/libpq-fe.h; do
  if [ -f "$src" ]; then
    cp "$src" "${PG_INSTALL_DIR}/include/"
    if [ "$src" != "${PG_INSTALL_DIR}/include/libpq/libpq-fe.h" ]; then
      cp "$src" "${PG_INSTALL_DIR}/include/libpq/"
    fi
    break
  fi
done

for src in "${PG_INSTALL_DIR}/include/libpq/libpq-events.h" \
           /build/postgresql-*/src/interfaces/libpq/libpq-events.h; do
  if [ -f "$src" ]; then
    cp "$src" "${PG_INSTALL_DIR}/include/"
    if [ "$src" != "${PG_INSTALL_DIR}/include/libpq/libpq-events.h" ]; then
      cp "$src" "${PG_INSTALL_DIR}/include/libpq/"
    fi
    break
  fi
done

# Create a stub libpq.a so the PostGIS link step can satisfy -lpq.
# As a server extension, PostGIS doesn't call libpq at runtime; the configure
# AC_CHECK_LIB check is bypassed via ac_cv_lib_pq_PQserverVersion below.
llvm-ar rcs "${PG_INSTALL_DIR}/lib/libpq.a"

XML2CONFIG="${WASIX_PREFIX}/bin/xml2-config"
if [ -f "${XML2CONFIG}" ]; then
  export XML2CONFIG
fi

PROJ_LIBS="-L${WASIX_PREFIX}/lib -lproj -lsqlite3 -lc++ -lc++abi -lunwind"
PROJ_CFLAGS="-I${WASIX_PREFIX}/include"

AC_VARS='
ac_cv_func_backtrace_symbols=no
ac_cv_func_vasprintf=yes
ac_cv_func_asprintf=yes
ac_cv_func_getopt_long=yes
ac_cv_func_strcasestr=yes
ac_cv_func_fseeko=no
ac_cv_func_ftello=no
ac_cv_func_iconvctl=no
ac_cv_func_libiconvctl=no
ac_cv_header_libpq_fe_h=yes
ac_cv_lib_pq_PQserverVersion=yes
ac_cv_file__opt_wasix_include_json_c_json_h=yes
'

CONF_VARS=()
for var in ${AC_VARS}; do
  CONF_VARS+=("${var}")
done

./configure \
  --host="${WASIX_TARGET}" \
  --prefix="${POSTGIS_INSTALL_DIR}" \
  --without-raster \
  --without-protobuf \
  --without-address-standardizer \
  --without-wagyu \
  --with-geosconfig="${GEOSCONFIG}" \
  --with-projdir="${WASIX_PREFIX}" \
  --with-jsondir="${WASIX_PREFIX}" \
  --with-xml2config="${XML2CONFIG}" \
  --with-pgconfig="${PG_CONFIG}" \
  CFLAGS="${CFLAGS}" \
  CXXFLAGS="${CXXFLAGS}" \
  LDFLAGS="${LDFLAGS}" \
  PROJ_CPPFLAGS="${PROJ_CFLAGS}" \
  PROJ_LIBS="${PROJ_LIBS}" \
  "${CONF_VARS[@]}"

# PostGIS' generated PGXS module links use `geos-config --clibs`, which only
# emits `-lgeos_c` (the C API). With static archives that is not enough:
# libgeos_c.a calls into the GEOS C++ core, so libgeos.a must be linked too,
# or geos::geom::* typeinfo/vtable symbols stay unresolved (e.g.
# _ZTIN4geos4geom5CurveE) and Wasmer fails them at dlopen time.
#
# Likewise libproj.a calls into SQLite (PROJ stores its CRS database in
# SQLite), so libsqlite3.a must be linked or sqlite3_* symbols stay unresolved
# and fail at runtime when PROJ's constructors run.
#
# The final shared-module link is also driven by CC and omits the C++ runtime.
# The WASIX sysroot has no libstdc++; the runtime is libc++ / libc++abi /
# libunwind. libunwind.a defines __wasm_lpad_context and libc++abi.a defines
# __gxx_personality_wasm0 / __cxa_*. Without these, --allow-undefined leaves
# them as GOT.mem imports.
#
# Order matters (archives scanned left-to-right): geos-config's -lgeos_c and
# PROJ's -lproj come first in SHLIB_LINK, then -lgeos / -lsqlite3, then the
# C++ runtime.
for makefile in postgis/Makefile topology/Makefile; do
  if [ -f "${makefile}" ]; then
    {
      echo
      echo "SHLIB_LINK += -L${WASIX_PREFIX}/lib -lgeos -lsqlite3 -lc++ -lc++abi -lunwind"
    } >> "${makefile}"
  fi
done

for subdir in liblwgeom libpgcommon postgis topology; do
  if [ -d "${subdir}" ]; then
    make -j"$(nproc)" -C "${subdir}"
  fi
done

if [ -d topology ]; then
  make -C topology topology.sql topology_upgrade.sql uninstall_topology.sql
fi

if [ -d extensions ]; then
  make -C extensions postgis_extension_helper.sql

  for subdir in extensions/postgis extensions/postgis_topology; do
    if [ -d "${subdir}" ]; then
      make -C "${subdir}"
    fi
  done
fi

mkdir -p "${POSTGIS_INSTALL_DIR}/lib"
cp postgis/postgis-3.so "${POSTGIS_INSTALL_DIR}/lib/" 2>/dev/null || \
  cp postgis-3.so "${POSTGIS_INSTALL_DIR}/lib/" 2>/dev/null || true
cp topology/postgis_topology-3.so "${POSTGIS_INSTALL_DIR}/lib/"

cp extensions/postgis/postgis.control "${POSTGIS_INSTALL_DIR}/" 2>/dev/null || true
cp extensions/postgis_topology/postgis_topology.control "${POSTGIS_INSTALL_DIR}/" 2>/dev/null || true

for sql in extensions/postgis/sql/postgis--*.sql \
           extensions/postgis_topology/sql/postgis_topology--*.sql; do
  cp "${sql}" "${POSTGIS_INSTALL_DIR}/" 2>/dev/null || true
done

ls -la "${POSTGIS_INSTALL_DIR}/lib/" || echo "No shared libraries found in install dir"

echo "PostGIS build complete. Libraries in ${POSTGIS_INSTALL_DIR}/lib/"
