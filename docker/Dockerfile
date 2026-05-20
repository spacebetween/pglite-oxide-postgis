FROM debian:bookworm-slim AS wasix-base

ENV DEBIAN_FRONTEND=noninteractive
ENV WASIX_SYSROOT=/opt/wasix-sysroot
ENV WASIX_PREFIX=/opt/wasix
ENV WASIX_TARGET=wasm32-wasi

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
  && curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key \
    | gpg --dearmor -o /usr/share/keyrings/llvm.gpg \
  && echo "deb [signed-by=/usr/share/keyrings/llvm.gpg] http://apt.llvm.org/bookworm/ llvm-toolchain-bookworm-18 main" \
    > /etc/apt/sources.list.d/llvm.list \
  && apt-get update && apt-get install -y --no-install-recommends \
    autoconf \
    automake \
    bison \
    build-essential \
    clang-18 \
    cmake \
    llvm-18 \
    flex \
    git \
    libtool \
    lld-18 \
    make \
    ninja-build \
    pkg-config \
    python3 \
    rsync \
    texinfo \
    wget \
    xz-utils \
    zstd \
  && update-alternatives --install /usr/bin/clang   clang   /usr/bin/clang-18   100 \
  && update-alternatives --install /usr/bin/clang++ clang++ /usr/bin/clang++-18 100 \
  && update-alternatives --install /usr/bin/llvm-ar     llvm-ar     /usr/bin/llvm-ar-18     100 \
  && update-alternatives --install /usr/bin/llvm-ranlib llvm-ranlib /usr/bin/llvm-ranlib-18 100 \
  && update-alternatives --install /usr/bin/llvm-nm     llvm-nm     /usr/bin/llvm-nm-18     100 \
  && update-alternatives --install /usr/bin/llvm-strip  llvm-strip  /usr/bin/llvm-strip-18  100 \
  && update-alternatives --install /usr/bin/wasm-ld     wasm-ld     /usr/bin/wasm-ld-18     100 \
  && rm -rf /var/lib/apt/lists/*

ENV CC=wasixcc
ENV CXX=wasixc++
ENV AR="llvm-ar"
ENV RANLIB="llvm-ranlib"
ENV NM="llvm-nm"
ENV LD=wasm-ld
ENV STRIP="llvm-strip"

FROM wasix-base AS wasix-sysroot

ARG WASIX_SYSROOT_RELEASE=v2026-05-12.1
ARG WASIX_SYSROOT_VARIANT=sysroot-exnref-ehpic

RUN mkdir -p /tmp/sysroot-extract \
  && curl -fsSL "https://github.com/wasix-org/wasix-libc/releases/download/${WASIX_SYSROOT_RELEASE}/${WASIX_SYSROOT_VARIANT}.tar.gz" \
    | tar -xz -C /tmp/sysroot-extract \
  && mv /tmp/sysroot-extract/*/sysroot "${WASIX_SYSROOT}" \
  && rm -rf /tmp/sysroot-extract

RUN printf '#!/bin/sh\nexec clang --target=%s --sysroot=%s "$@"\n' \
    "${WASIX_TARGET}" "${WASIX_SYSROOT}" > /usr/local/bin/wasixcc \
  && chmod +x /usr/local/bin/wasixcc

RUN printf '#!/bin/sh\nexec clang++ --target=%s --sysroot=%s -fwasm-exceptions "$@"\n' \
    "${WASIX_TARGET}" "${WASIX_SYSROOT}" > /usr/local/bin/wasixc++ \
  && chmod +x /usr/local/bin/wasixc++

RUN CLANG_LIB_DIR=$(clang -print-resource-dir)/lib/wasi \
  && mkdir -p "${CLANG_LIB_DIR}" \
  && cp "${WASIX_SYSROOT}/lib/wasm32-wasi/libclang_rt.builtins-wasm32.a" "${CLANG_LIB_DIR}/" \
  && echo "Installed compiler-rt builtins to ${CLANG_LIB_DIR}"

RUN printf '%s\n' \
  'set(CMAKE_SYSTEM_NAME Generic)' \
  'set(CMAKE_SYSTEM_VERSION 1)' \
  'set(CMAKE_SYSTEM_PROCESSOR wasm32)' \
  'set(CMAKE_CROSSCOMPILING TRUE)' \
  'set(CMAKE_C_COMPILER /usr/local/bin/wasixcc)' \
  'set(CMAKE_CXX_COMPILER /usr/local/bin/wasixc++)' \
  'set(CMAKE_AR /usr/bin/llvm-ar)' \
  'set(CMAKE_RANLIB /usr/bin/llvm-ranlib)' \
  'set(CMAKE_NM /usr/bin/llvm-nm)' \
  'set(CMAKE_LINKER /usr/bin/wasm-ld)' \
  'set(CMAKE_STRIP /usr/bin/llvm-strip)' \
  "set(CMAKE_C_COMPILER_TARGET ${WASIX_TARGET})" \
  "set(CMAKE_CXX_COMPILER_TARGET ${WASIX_TARGET})" \
  'set(CMAKE_C_COMPILER_WORKS 1)' \
  'set(CMAKE_CXX_COMPILER_WORKS 1)' \
  'set(CMAKE_SIZEOF_VOID_P 4)' \
  "set(CMAKE_SYSROOT ${WASIX_SYSROOT})" \
  "set(CMAKE_C_FLAGS_INIT \"--target=${WASIX_TARGET} --sysroot=${WASIX_SYSROOT}\")" \
  "set(CMAKE_CXX_FLAGS_INIT \"--target=${WASIX_TARGET} --sysroot=${WASIX_SYSROOT} -fwasm-exceptions\")" \
  'set(CMAKE_EXE_LINKER_FLAGS_INIT "-nostartfiles -Wl,--no-entry")' \
  > "${WASIX_SYSROOT}/clang-wasm.cmake_toolchain"

RUN wasixcc -v 2>&1 | head -5 \
  && echo "Toolchain OK" \
  && ls "${WASIX_SYSROOT}/lib/wasm32-wasi/" | head -5 \
  && ls "${WASIX_SYSROOT}/include/" | head -5

FROM wasix-sysroot AS pg-build

WORKDIR /build

COPY scripts/docker_pg.sh /build/scripts/docker_pg.sh

ARG PG_VERSION=17.5
ENV PG_VERSION=${PG_VERSION}

RUN bash /build/scripts/docker_pg.sh

FROM pg-build AS geos-deps

WORKDIR /build/deps

ENV CFLAGS="--target=${WASIX_TARGET} --sysroot=${WASIX_SYSROOT} -O2 -fPIC -matomics -mbulk-memory -mmutable-globals"
ENV CXXFLAGS="--target=${WASIX_TARGET} --sysroot=${WASIX_SYSROOT} -O2 -fPIC -fwasm-exceptions -matomics -mbulk-memory -mmutable-globals"
ENV PROJ_CFLAGS="--target=${WASIX_TARGET} --sysroot=${WASIX_SYSROOT} -O2 -fPIC"
ENV PROJ_CXXFLAGS="--target=${WASIX_TARGET} --sysroot=${WASIX_SYSROOT} -O2 -fPIC -fwasm-exceptions"
ENV GEOS_CFLAGS="--target=${WASIX_TARGET} --sysroot=${WASIX_SYSROOT} -O2 -fPIC"
ENV GEOS_CXXFLAGS="--target=${WASIX_TARGET} --sysroot=${WASIX_SYSROOT} -O2 -fPIC -fwasm-exceptions"
ENV LDFLAGS="-L${WASIX_PREFIX}/lib"
ENV PKG_CONFIG_PATH="${WASIX_PREFIX}/lib/pkgconfig"
ENV PKG_CONFIG_LIBDIR="${WASIX_PREFIX}/lib/pkgconfig"
ENV CMAKE_TOOLCHAIN_FILE="${WASIX_SYSROOT}/clang-wasm.cmake_toolchain"

# json-c 0.18 (cmake)
ARG JSON_C_VERSION=json-c-0.18-20240915
RUN git clone --depth 1 --branch ${JSON_C_VERSION} https://github.com/json-c/json-c.git json-c \
  && mkdir -p json-c/build && cd json-c/build \
  && cmake .. \
    -DCMAKE_TOOLCHAIN_FILE=${CMAKE_TOOLCHAIN_FILE} \
    -DCMAKE_SYSROOT=${WASIX_SYSROOT} \
    -DCMAKE_INSTALL_PREFIX=${WASIX_PREFIX} \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTING=OFF \
    -DDISABLE_EXTRA_LIBS=ON \
    -DBUILD_APPS=OFF \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DHAVE_SNPRINTF:BOOL=ON \
    -DHAVE_VASPRINTF:BOOL=ON \
    -DHAVE_VSNPRINTF:BOOL=ON \
    -DHAVE_STRDUP:BOOL=ON \
    "-DCMAKE_C_FLAGS=${CFLAGS} -Wno-error=macro-redefined" \
  && cmake --build . --parallel $(nproc) \
  && cmake --install . \
  && rm -rf /build/deps/json-c

# libxml2 2.13.x (cmake — autotools unusable for WASM cross-compilation)
ARG LIBXML2_VERSION=v2.13.7
RUN git clone --depth 1 --branch ${LIBXML2_VERSION} https://gitlab.gnome.org/GNOME/libxml2.git libxml2 \
  && mkdir -p libxml2/build && cd libxml2/build \
  && cmake .. \
    -DCMAKE_TOOLCHAIN_FILE=${CMAKE_TOOLCHAIN_FILE} \
    -DCMAKE_SYSROOT=${WASIX_SYSROOT} \
    -DCMAKE_INSTALL_PREFIX=${WASIX_PREFIX} \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DLIBXML2_WITH_PYTHON=OFF \
    -DLIBXML2_WITH_LZMA=OFF \
    -DLIBXML2_WITH_ZLIB=OFF \
    -DLIBXML2_WITH_HTTP=OFF \
    -DLIBXML2_WITH_FTP=OFF \
    -DLIBXML2_WITH_ICONV=OFF \
    -DLIBXML2_WITH_TESTS=OFF \
    -DLIBXML2_WITH_PROGRAMS=OFF \
    -DLIBXML2_WITH_THREADS=OFF \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    "-DCMAKE_C_FLAGS=${CFLAGS} -Wno-error=macro-redefined" \
  && cmake --build . --parallel $(nproc) \
  && cmake --install . \
  && rm -rf /build/deps/libxml2

# SQLite — native sqlite3 for PROJ proj.db init + WASIX static lib
# SQLite git repo has no CMakeLists.txt; use amalgamation from release tarball
ARG SQLITE_AMALG_VERSION=3460100
ARG SQLITE_YEAR=2024
RUN curl -fsSL "https://www.sqlite.org/${SQLITE_YEAR}/sqlite-autoconf-${SQLITE_AMALG_VERSION}.tar.gz" \
    | tar -xz -C /tmp \
  && cd /tmp/sqlite-autoconf-${SQLITE_AMALG_VERSION} \
  \
  # Native executable — must be native gcc, not wasixcc (PROJ needs to run it at build time)
  && gcc -O2 -DSQLITE_ENABLE_COLUMN_METADATA=1 \
    shell.c sqlite3.c -lpthread -ldl -lm \
    -o /usr/local/bin/sqlite3-native \
  \
  # WASIX static library — single-file amalgamation compile
  && wasixcc ${CFLAGS} -DSQLITE_ENABLE_COLUMN_METADATA=1 -c sqlite3.c -o /tmp/sqlite3.o \
  && llvm-ar rcs ${WASIX_PREFIX}/lib/libsqlite3.a /tmp/sqlite3.o \
  && mkdir -p ${WASIX_PREFIX}/include ${WASIX_PREFIX}/lib/pkgconfig \
  && cp sqlite3.h sqlite3ext.h ${WASIX_PREFIX}/include/ \
  && printf 'prefix=%s\nlibdir=${prefix}/lib\nincludedir=${prefix}/include\n\nName: SQLite\nDescription: SQLite amalgamation\nVersion: 3.46.1\nLibs: -L${libdir} -lsqlite3\nCflags: -I${includedir}\n' "${WASIX_PREFIX}" \
    > ${WASIX_PREFIX}/lib/pkgconfig/sqlite3.pc \
  \
  && rm -rf /tmp/sqlite-autoconf-${SQLITE_AMALG_VERSION} /tmp/sqlite3.o

# PROJ 9.7.0 (cmake, depends on sqlite)
ARG PROJ_VERSION=9.7.0
RUN git clone --depth 1 --branch ${PROJ_VERSION} https://github.com/OSGeo/PROJ.git proj \
  && mkdir -p proj/build && cd proj/build \
  && cmake .. \
    -DCMAKE_TOOLCHAIN_FILE=${CMAKE_TOOLCHAIN_FILE} \
    -DCMAKE_SYSROOT=${WASIX_SYSROOT} \
    -DCMAKE_INSTALL_PREFIX=${WASIX_PREFIX} \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTING=OFF \
    -DBUILD_PROJSYNC=OFF \
    -DBUILD_CCT=OFF \
    -DBUILD_CS2CS=OFF \
    -DBUILD_GEOD=OFF \
    -DBUILD_GIE=OFF \
    -DBUILD_PROJ=OFF \
    -DBUILD_PROJINFO=OFF \
    -DBUILD_PROJJSON=OFF \
    -DENABLE_CURL=OFF \
    -DENABLE_TIFF=OFF \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    "-DCMAKE_C_FLAGS=${PROJ_CFLAGS}" \
    "-DCMAKE_CXX_FLAGS=${PROJ_CXXFLAGS}" \
    -DSQLITE3_INCLUDE_DIR=${WASIX_PREFIX}/include \
    -DSQLITE3_LIBRARY=${WASIX_PREFIX}/lib/libsqlite3.a \
    -DEXE_SQLITE3=/usr/local/bin/sqlite3-native \
  && cmake --build . --parallel $(nproc) \
  && cmake --install . \
  && rm -rf /build/deps/proj

# GEOS 3.14.0 (cmake, C++ with wasm-exceptions)
ARG GEOS_VERSION=3.14.0
RUN git clone --depth 1 --branch ${GEOS_VERSION} https://github.com/libgeos/geos.git geos \
  && mkdir -p geos/build && cd geos/build \
  && cmake .. \
    -DCMAKE_TOOLCHAIN_FILE=${CMAKE_TOOLCHAIN_FILE} \
    -DCMAKE_SYSROOT=${WASIX_SYSROOT} \
    -DCMAKE_INSTALL_PREFIX=${WASIX_PREFIX} \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    "-DCMAKE_C_FLAGS=${GEOS_CFLAGS}" \
    "-DCMAKE_CXX_FLAGS=${GEOS_CXXFLAGS} -DFE_ALL_EXCEPT=0 -DFE_INEXACT=0 -DFE_DIVBYZERO=0 -DFE_INVALID=0 -DFE_OVERFLOW=0 -DFE_UNDERFLOW=0" \
    -DCMAKE_EXE_LINKER_FLAGS="-Wl,--allow-undefined" \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTING=OFF \
    -DBUILD_DOCUMENTATION=OFF \
    -DGEOS_BUILD_DEVELOPER=OFF \
     -DBUILD_GEOSOP=OFF \
  && cmake --build . --parallel $(nproc) \
  && cmake --install . \
  && rm -rf /build/deps/geos

FROM geos-deps AS postgis-build

WORKDIR /build

ENV PG_INSTALL_DIR=/build/pg_install
ENV PG_CONFIG=/build/pg_install/bin/pg_config
ENV GEOS_CONFIG=${WASIX_PREFIX}/bin/geos-config

COPY scripts/docker_postgis.sh /build/scripts/docker_postgis.sh

ARG POSTGIS_VERSION=3.5.2
ENV POSTGIS_VERSION=${POSTGIS_VERSION}

RUN bash /build/scripts/docker_postgis.sh

FROM postgis-build AS postgis-package

WORKDIR /build

ARG BINARYEN_VERSION=version_129

RUN set -e; \
    ARCH=$(uname -m); \
    case "$ARCH" in \
      aarch64) BINARYEN_ASSET="binaryen-${BINARYEN_VERSION}-aarch64-linux.tar.gz" ;; \
      x86_64)  BINARYEN_ASSET="binaryen-${BINARYEN_VERSION}-x86_64-linux.tar.gz" ;; \
      *) echo "Unsupported arch: $ARCH"; exit 1 ;; \
    esac; \
    curl -fsSL \
      "https://github.com/WebAssembly/binaryen/releases/download/${BINARYEN_VERSION}/${BINARYEN_ASSET}" \
      | tar -xz --strip-components=1 -C /usr/local; \
    wasm-opt --version

COPY scripts/docker_package.sh /build/scripts/docker_package.sh

RUN bash /build/scripts/docker_package.sh

FROM postgis-package AS aot-compile

ARG WASMER_VERSION=v7.2.0-alpha.2
ARG BINARYEN_VERSION=version_129

# Download wasmer CLI (includes LLVM backend) and wasm-opt (Binaryen) for the
# container's architecture.  Both are self-contained tarballs from GitHub releases.
RUN set -e; \
    ARCH=$(uname -m); \
    case "$ARCH" in \
      aarch64) \
        WASMER_ASSET="wasmer-linux-aarch64.tar.gz" ; \
        BINARYEN_ASSET="binaryen-${BINARYEN_VERSION}-aarch64-linux.tar.gz" ;; \
      x86_64) \
        WASMER_ASSET="wasmer-linux-amd64.tar.gz" ; \
        BINARYEN_ASSET="binaryen-${BINARYEN_VERSION}-x86_64-linux.tar.gz" ;; \
      *) echo "Unsupported arch: $ARCH"; exit 1 ;; \
    esac; \
    curl -fsSL \
      "https://github.com/wasmerio/wasmer/releases/download/${WASMER_VERSION}/${WASMER_ASSET}" \
      | tar -xz -C /usr/local; \
    curl -fsSL \
      "https://github.com/WebAssembly/binaryen/releases/download/${BINARYEN_VERSION}/${BINARYEN_ASSET}" \
      | tar -xz --strip-components=1 -C /usr/local; \
    wasmer --version; \
    wasm-opt --version

COPY scripts/docker_aot.sh /build/scripts/docker_aot.sh

RUN bash /build/scripts/docker_aot.sh
