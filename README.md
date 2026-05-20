# pglite-oxide-postgis

Standalone build project for compiling PostGIS as a WASIX PostgreSQL extension for
`pglite-oxide`.

## Contents

- `docker/Dockerfile` - multi-stage WASIX build for PostgreSQL headers, geospatial
  dependencies, PostGIS, and packaging.
- `scripts/docker_pg.sh` - prepares PostgreSQL server headers and a PGXS stub for
  WASIX extension builds.
- `scripts/docker_postgis.sh` - builds PostGIS with the WASIX toolchain.
- `scripts/docker_package.sh` - packages the extension using pglite-oxide archive
  layout.
- `pglited-oxide/` - standalone Rust TCP server consumed by `ex_pglite_oxide`.
- `.github/workflows/pglited-oxide-release.yml` - builds release tarballs for
  Apple Silicon macOS and GitHub's x64 Ubuntu runners.
- `extensions/` - extension catalog metadata.
- `artifacts/postgis.tar.zst` - copied build artifact from the original app.
- `docs/verification-2026-05-18.md` - verification notes for the copied artifact.

## Build

```sh
docker build \
  -t pglite-oxide-postgis \
  -f docker/Dockerfile \
  --build-arg PG_VERSION=17.5 \
  --build-arg POSTGIS_VERSION=3.5.2 \
  .
```

Extract the packaged extension:

```sh
mkdir -p dist
docker run --rm -v "$PWD/dist:/out" pglite-oxide-postgis \
  cp /build/extensions/postgis.tar.zst /out/
```

## Compatibility

PostGIS server extensions are tied to the PostgreSQL major version they were
built against. Match `PG_VERSION` to the PostgreSQL version embedded in the
target `pglite-oxide` release.

The copied artifact in `artifacts/postgis.tar.zst` was built for PostgreSQL
16.0/16.x and did not load in `pglite-oxide` 0.5.0, which reports PostgreSQL
17.5. Rebuild against the target runtime before publishing a release artifact.

## Packaging Layout

`pglite-oxide` expects extension archives to unpack at the archive root:

```text
lib/postgresql/postgis-3.so
lib/postgresql/postgis_topology-3.so
share/postgresql/extension/postgis.control
share/postgresql/extension/postgis--3.5.2.sql
```

The standalone packaging script now emits that layout. The copied artifact under
`artifacts/` retains the original layout for reference.

## Smoke Test

A release should pass at least:

```sql
CREATE EXTENSION IF NOT EXISTS postgis;
SELECT postgis_full_version();
SELECT ST_Area(ST_Buffer(ST_GeomFromText('POINT(0 0)'), 1));
```

## pglited-oxide Release Assets

The Elixir package downloads prebuilt `pglited-oxide` binaries from GitHub
release assets. Build and publish them with:

```sh
git tag pglited-oxide-v0.1.2
git push origin pglited-oxide-v0.1.2
```

The workflow publishes:

```text
pglited-oxide-aarch64-apple-darwin.tar.gz
pglited-oxide-aarch64-apple-darwin.tar.gz.sha256
pglited-oxide-x86_64-unknown-linux-gnu.tar.gz
pglited-oxide-x86_64-unknown-linux-gnu.tar.gz.sha256
```

`ubuntu-latest` GitHub-hosted runners are x64, so the Linux asset is the CI
target. The macOS asset is built on `macos-14`, which is Apple Silicon.
