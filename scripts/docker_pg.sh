#!/usr/bin/env bash
set -euxo pipefail

PG_VERSION=${PG_VERSION:-17.5}
PG_SOURCE_URL="https://ftp.postgresql.org/pub/source/v${PG_VERSION}/postgresql-${PG_VERSION}.tar.bz2"
PG_INSTALL_DIR=/build/pg_install
PG_SRC_DIR=/build/postgresql-${PG_VERSION}

if [ ! -d "${PG_SRC_DIR}" ]; then
  curl -fsSL "${PG_SOURCE_URL}" | tar -xj -C /build
fi

cd "${PG_SRC_DIR}"

# Run a native configure + make generated-headers to produce all auto-generated headers
# (nodetags.h, pg_attribute_d.h, errcodes.h, gram.h, etc.) that are absent from the tarball.
# These generated files live in src/include/ and are copied to pg_install later.
CC=gcc CXX=g++ AR=ar RANLIB=ranlib LDFLAGS="" CFLAGS="" \
  ./configure \
  --prefix=/tmp/pg_native_headers \
  --without-readline --without-zlib --without-icu --without-llvm \
  --without-pam --without-ldap --without-gssapi --without-openssl \
  --without-libxml --without-libxslt --without-python --without-perl \
  --without-tcl --without-systemd --without-bonjour \
  2>&1 | tail -3
make -j"$(nproc)" submake-generated-headers 2>&1 | tail -5 || \
  make -j"$(nproc)" -C src/backend generated-headers 2>&1 | tail -5 || \
  echo "WARNING: generated-headers make target not found, continuing"
echo "Native generated-headers complete"

export CC=wasixcc
export CXX=wasixc++
export AR="llvm-ar"
export RANLIB="llvm-ranlib"
export STRIP="llvm-strip"

CFLAGS="--target=${WASIX_TARGET} --sysroot=${WASIX_SYSROOT} -O2 -D_GNU_SOURCE -DGENERIC_LONG_VALUES"

MISSING_FUNCS='
ac_cv_func_getrusage=no
ac_cv_func_sched_yield=no
ac_cv_func_fseeko=no
ac_cv_func_ftello=no
ac_cv_func_strtoll=yes
ac_cv_func_strtoull=yes
ac_cv_func_mkdtemp=no
ac_cv_func_posix_fallocate=no
ac_cv_func_preadv=no
ac_cv_func_pwritev=no
ac_cv_func_sync_file_range=no
ac_cv_func_copyfile=no
ac_cv_func_fls=no
ac_cv_func_getpeereid=no
ac_cv_func_mblen=no
ac_cv_func_mbrlen=no
ac_cv_func_mbrtowc=no
ac_cv_func_mbstowcs=no
ac_cv_func_mbtowc=no
ac_cv_func_posix_fadvise=no
ac_cv_func_setproctitle=no
ac_cv_func_setproctitle_fast=no
ac_cv_func_strlcpy=no
ac_cv_func_strnlen=no
ac_cv_func_wcstombs=no
ac_cv_func_wctomb=no
ac_cv_func_gai_strerror=no
ac_cv_func_getaddrinfo=no
ac_cv_func_inet_aton=no
'

CONF_VARS=()
for var in ${MISSING_FUNCS}; do
  CONF_VARS+=("${var}")
done

# Force correct 64-bit int64 for wasm32: configure running on a 64-bit host detects
# sizeof(long)==8 and sets HAVE_LONG_INT_64, making int64=long (32-bit on wasm32).
# Override to select HAVE_LONG_LONG_INT_64 so int64=long long (always 64-bit).
CONF_VARS+=(
  "ac_cv_have_long_int_64=no"
  "ac_cv_have_long_long_int_64=yes"
)

./configure \
  --host="${WASIX_TARGET}" \
  --prefix="${PG_INSTALL_DIR}" \
  --without-readline \
  --without-zlib \
  --without-icu \
  --without-llvm \
  --without-pam \
  --without-ldap \
  --without-gssapi \
  --without-openssl \
  --without-libxml \
  --without-libxslt \
  --without-python \
  --without-perl \
  --without-tcl \
  --without-systemd \
  --without-bonjour \
  CFLAGS="${CFLAGS}" \
  "${CONF_VARS[@]}" || true

echo "Configure completed (warnings expected for cross-compilation)"

mkdir -p "${PG_INSTALL_DIR}/include/server"
mkdir -p "${PG_INSTALL_DIR}/include/libpq"
mkdir -p "${PG_INSTALL_DIR}/lib"
mkdir -p "${PG_INSTALL_DIR}/bin"
mkdir -p "${PG_INSTALL_DIR}/share"

cp src/include/pg_config.h "${PG_INSTALL_DIR}/include/" 2>/dev/null || \
  cp src/include/pg_config.h.in "${PG_INSTALL_DIR}/include/pg_config.h" 2>/dev/null || true

for header in c.h postgres.h postgres_ext.h fmgr.h; do
  cp "src/include/${header}" "${PG_INSTALL_DIR}/include/" 2>/dev/null || true
done

cp -rL src/include/*.h "${PG_INSTALL_DIR}/include/" 2>/dev/null || true
# PostgreSQL source has no src/include/server/ directory — server headers live as subdirectories
# directly under src/include/ (e.g. src/include/utils/elog.h). PostgreSQL's own 'make install'
# copies those subdirs into ${prefix}/include/server/. Replicate that here, and also copy into
# include/ directly so postgres.h's #include "utils/elog.h" resolves from its own directory.
for subdir in src/include/*/; do
  base=$(basename "${subdir}")
  mkdir -p "${PG_INSTALL_DIR}/include/server/${base}"
  cp -rL "${subdir}." "${PG_INSTALL_DIR}/include/server/${base}/"
  mkdir -p "${PG_INSTALL_DIR}/include/${base}"
  cp -rL "${subdir}." "${PG_INSTALL_DIR}/include/${base}/"
done

echo "utils/elog.h in include/:        $(ls ${PG_INSTALL_DIR}/include/utils/elog.h 2>/dev/null && echo OK || echo MISSING)"
echo "utils/elog.h in include/server/: $(ls ${PG_INSTALL_DIR}/include/server/utils/elog.h 2>/dev/null && echo OK || echo MISSING)"
cp -r src/include/libpq/*.h "${PG_INSTALL_DIR}/include/libpq/" 2>/dev/null || true
# Real PostgreSQL installs libpq-fe.h and libpq-events.h at the top-level includedir.
# These headers live under src/interfaces/libpq/ in PostgreSQL source tarballs.
cp src/interfaces/libpq/libpq-fe.h     "${PG_INSTALL_DIR}/include/libpq/" 2>/dev/null || true
cp src/interfaces/libpq/libpq-events.h "${PG_INSTALL_DIR}/include/libpq/" 2>/dev/null || true
cp src/interfaces/libpq/libpq-fe.h     "${PG_INSTALL_DIR}/include/" 2>/dev/null || true
cp src/interfaces/libpq/libpq-events.h "${PG_INSTALL_DIR}/include/" 2>/dev/null || true
cp -r src/include/port/*.h "${PG_INSTALL_DIR}/include/" 2>/dev/null || true

if [ -f src/include/pg_config.h ]; then
  cp src/include/pg_config.h "${PG_INSTALL_DIR}/include/pg_config.h"
elif [ -f src/include/pg_config.h.in ]; then
  sed 's/#undef/#define/g' src/include/pg_config.h.in > "${PG_INSTALL_DIR}/include/pg_config.h"
fi

# The sed hack converts "#undef FOO" to "#define FOO" (no value).
# Any macro used in a #if expression must have a concrete numeric value.
# Append WASM32 overrides using #undef+#define pairs to stomp the empty defines.
cat >> "${PG_INSTALL_DIR}/include/pg_config.h" << 'WASM32CFG'
/* WASM32/WASIX numeric overrides — sed leaves these empty, #if needs integers */
#undef ALIGNOF_DOUBLE
#define ALIGNOF_DOUBLE 8
#undef ALIGNOF_INT
#define ALIGNOF_INT 4
#undef ALIGNOF_LONG
#define ALIGNOF_LONG 4
#undef ALIGNOF_LONG_LONG_INT
#define ALIGNOF_LONG_LONG_INT 8
#undef ALIGNOF_SHORT
#define ALIGNOF_SHORT 2
#undef ALIGNOF_PG_INT128_TYPE
#define ALIGNOF_PG_INT128_TYPE 8
#undef BLCKSZ
#define BLCKSZ 8192
#undef MAXIMUM_ALIGNOF
#define MAXIMUM_ALIGNOF 8
#undef RELSEG_SIZE
#define RELSEG_SIZE 131072
#undef SIZEOF_BOOL
#define SIZEOF_BOOL 1
#undef SIZEOF_INT
#define SIZEOF_INT 4
#undef SIZEOF_LONG
#define SIZEOF_LONG 4
#undef SIZEOF_LONG_LONG
#define SIZEOF_LONG_LONG 8
#undef SIZEOF_OFF_T
#define SIZEOF_OFF_T 8
#undef SIZEOF_SIZE_T
#define SIZEOF_SIZE_T 4
#undef SIZEOF_VOID_P
#define SIZEOF_VOID_P 4
#undef HAVE_STDINT_H
#define HAVE_STDINT_H 1
#undef HAVE_INTTYPES_H
#define HAVE_INTTYPES_H 1
#undef HAVE_STRINGS_H
#define HAVE_STRINGS_H 1
/* int64 type: configure on a 64-bit host sets HAVE_LONG_INT_64, making int64=long
 * (32-bit on wasm32). Force HAVE_LONG_LONG_INT_64 so int64=long long (64-bit). */
#undef HAVE_LONG_INT_64
#define HAVE_LONG_LONG_INT_64 1
/* PG_INT*_TYPE — used by c.h to form int8/int16/int32/int64/uint* typedefs */
#undef PG_INT8_TYPE
#define PG_INT8_TYPE signed char
#undef PG_INT16_TYPE
#define PG_INT16_TYPE short
#undef PG_INT32_TYPE
#define PG_INT32_TYPE int
#undef PG_INT64_TYPE
#define PG_INT64_TYPE long long
#undef PG_UINT8_TYPE
#define PG_UINT8_TYPE unsigned char
#undef PG_UINT16_TYPE
#define PG_UINT16_TYPE unsigned short
#undef PG_UINT32_TYPE
#define PG_UINT32_TYPE unsigned int
#undef PG_UINT64_TYPE
#define PG_UINT64_TYPE unsigned long long
/* HAVE_DECL_* — sed leaves these empty; #if HAVE_DECL_FOO must be 0 or 1 */
#undef HAVE_DECL_POSIX_FADVISE
#define HAVE_DECL_POSIX_FADVISE 0
#undef HAVE_DECL_FDATASYNC
#define HAVE_DECL_FDATASYNC 0
#undef HAVE_DECL_STRLCPY
#define HAVE_DECL_STRLCPY 0
#undef HAVE_DECL_STRLCAT
#define HAVE_DECL_STRLCAT 0
#undef HAVE_DECL_SNPRINTF
#define HAVE_DECL_SNPRINTF 1
#undef HAVE_DECL_VSNPRINTF
#define HAVE_DECL_VSNPRINTF 1
#undef HAVE_DECL_STRNLEN
#define HAVE_DECL_STRNLEN 0
/* c.h guards uint8/uint16/uint32/int8/int16/int32 typedefs with #ifndef HAVE_*.
 * sed converts "#undef HAVE_UINT8" to "#define HAVE_UINT8" (empty = defined),
 * making #ifndef HAVE_UINT8 false and skipping the typedef. Undef them all so
 * c.h creates its own typedefs from its built-in definitions. */
#undef HAVE_INT8
#undef HAVE_INT16
#undef HAVE_INT32
#undef HAVE_INT64
#undef HAVE_UINT8
#undef HAVE_UINT16
#undef HAVE_UINT32
#undef HAVE_UINT64
/* XLOG_BLCKSZ — sed leaves empty; char data[XLOG_BLCKSZ] in a union needs a value */
#undef XLOG_BLCKSZ
#define XLOG_BLCKSZ 8192
/* PG_INT128_TYPE — wasm32 has no __int128; undef so c.h skips the int128 typedef */
#undef PG_INT128_TYPE
/* PG_PRINTF_ATTRIBUTE — sed leaves empty; __attribute__((format(,f,a))) is invalid */
#undef PG_PRINTF_ATTRIBUTE
#define PG_PRINTF_ATTRIBUTE gnu_printf
WASM32CFG

# Always write our WASM32 pg_config_ext.h. configure's generated version sets
# PG_INT64_TYPE=long (32-bit on wasm32); we must use long long (always 64-bit).
cat > "${PG_INSTALL_DIR}/include/pg_config_ext.h" << 'EXTEOF'
#ifndef PG_CONFIG_EXT_H
#define PG_CONFIG_EXT_H
/* WASM32: long long is 64-bit, long is 32-bit */
#define INT64_FORMAT "%lld"
#define UINT64_FORMAT "%llu"
#define PG_INT64_TYPE long long int
#endif /* PG_CONFIG_EXT_H */
EXTEOF

# pg_config_os.h is created by native configure as a symlink to port/linux.h.
# Always write our WASM32 stub — the Linux-native version pulls in host-specific
# includes incompatible with WASIX. rm -f clears any dangling symlink first.
rm -f "${PG_INSTALL_DIR}/include/pg_config_os.h"
cat > "${PG_INSTALL_DIR}/include/pg_config_os.h" << 'OSEOF'
#ifndef PG_CONFIG_OS_H
#define PG_CONFIG_OS_H
/* Minimal WASM32/WASIX stub — enough for PostGIS libpgcommon compilation */
#define HAVE_STDINT_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_STRINGS_H 1
#define HAVE_SYS_TYPES_H 1
#define SIZEOF_VOID_P 4
#define SIZEOF_LONG 4
#define SIZEOF_SIZE_T 4
#define SIZEOF_OFF_T 8
#define SIZEOF_LONG_LONG 8
#endif /* PG_CONFIG_OS_H */
OSEOF

cat > "${PG_INSTALL_DIR}/bin/pg_config" << 'PGCFGEOF'
#!/bin/sh
PG_INSTALL_DIR=/build/pg_install
case "$1" in
  --includedir|--includedir-server)
    echo "${PG_INSTALL_DIR}/include"
    ;;
  --pkgincludedir)
    echo "${PG_INSTALL_DIR}/include/server"
    ;;
  --libdir|--pkglibdir)
    echo "${PG_INSTALL_DIR}/lib"
    ;;
  --bindir)
    echo "${PG_INSTALL_DIR}/bin"
    ;;
  --sharedir)
    echo "${PG_INSTALL_DIR}/share"
    ;;
  --version)
    echo "PostgreSQL __PG_VERSION__"
    ;;
  --cppflags)
    echo "-I${PG_INSTALL_DIR}/include"
    ;;
  --ldflags)
    echo "-L${PG_INSTALL_DIR}/lib"
    ;;
  --pgxs)
    echo "${PG_INSTALL_DIR}/lib/pgxs/src/makefiles/pgxs.mk"
    ;;
  --configure)
    echo "--host=wasm32-wasi --prefix=${PG_INSTALL_DIR}"
    ;;
  *)
    echo ""
    ;;
esac
PGCFGEOF
sed -i "s/__PG_VERSION__/${PG_VERSION}/g" "${PG_INSTALL_DIR}/bin/pg_config"
chmod +x "${PG_INSTALL_DIR}/bin/pg_config"

mkdir -p "${PG_INSTALL_DIR}/lib/pgxs/src/makefiles"
# Always use our WASM-compatible stub — the native pgxs.mk (created by configure)
# references Makefile.shlib which doesn't exist in our cross-compile setup.
cat > "${PG_INSTALL_DIR}/lib/pgxs/src/makefiles/pgxs.mk" << 'PGXSEOF'
PG_INSTALL_DIR = /build/pg_install
libdir := $(PG_INSTALL_DIR)/lib
pkglibdir = $(libdir)
includedir := $(PG_INSTALL_DIR)/include
includedir_server = $(includedir)/server
pkgincludedir = $(includedir_server)
bindir := $(PG_INSTALL_DIR)/bin
datadir := $(PG_INSTALL_DIR)/share
localedir = no

# DLSUFFIX is normally provided by Makefile.shlib; hardcode for WASM cross-compile.
DLSUFFIX = .so
INSTALL_SHLIB = install -m 755
MKDIR_P = mkdir -p

override CFLAGS := -I$(includedir) -I$(includedir_server) -matomics -mbulk-memory -mmutable-globals

# WASIX dynamic side-module linker flags.
# The WASIX runtime creates its memory as shared=true; every extension .so that
# imports env.memory must also declare it as shared, or Wasmer's type check fails.
LDFLAGS_SL := \
  -Xlinker --shared-memory \
  -Xlinker --no-check-features \
  -Xlinker --extra-features=atomics,bulk-memory,mutable-globals \
  -Xlinker --export=__wasm_call_ctors \
  -Xlinker --export-if-defined=__wasm_apply_data_relocs

ifdef MODULE_big
shlib = $(MODULE_big)$(DLSUFFIX)
endif

ifndef PG_CONFIG
PG_CONFIG = $(bindir)/pg_config
endif

override CFLAGS += $(PG_CPPFLAGS)

all: $(shlib)

# Link all OBJS into the shared library (MODULE_big case).
$(shlib): $(OBJS)
	$(CC) $(CFLAGS) $(LDFLAGS) $(LDFLAGS_SL) -shared -o $@ $(OBJS) $(SHLIB_LINK)

%.o: %.c
	$(CC) $(CFLAGS) $(CPPFLAGS) -fPIC -c -o $@ $<

install: all installdirs
	$(INSTALL_SHLIB) $(shlib) '$(DESTDIR)$(pkglibdir)/$(shlib)'

installdirs:
	$(MKDIR_P) '$(DESTDIR)$(pkglibdir)'

uninstall:
	rm -f '$(DESTDIR)$(pkglibdir)/$(shlib)'

clean:
	rm -f $(OBJS) $(shlib)

.PHONY: all install installdirs uninstall clean
PGXSEOF

echo "PostgreSQL headers and pg_config installed to ${PG_INSTALL_DIR}"
echo "Header count: $(find ${PG_INSTALL_DIR}/include -name '*.h' | wc -l)"
