# PostGIS Smoke Test

Minimal Rust binary that verifies a `postgis.tar.zst` archive is compatible with
pglite-oxide 0.5.0.

## Usage

```sh
cargo run --release -- ../../dist/postgis.tar.zst
```

Or pass any path to the archive:

```sh
cargo run --release -- /path/to/postgis.tar.zst
```

## What it checks

1. Opens a temporary pglite-oxide database and confirms the PostgreSQL version.
2. Installs the extension archive via `install_extension_archive`.
3. Runs `CREATE EXTENSION IF NOT EXISTS postgis`.
4. Runs `SELECT postgis_full_version()` and
   `SELECT ST_Area(ST_Buffer(ST_GeomFromText('POINT(0 0)'), 1))`.

## Current status / blocker

As of pglite-oxide 0.5.0 the test fails at step 3 with:

```
could not load library "/lib/postgresql/postgis-3.so": failed to load module:
Failed to spawn module: compile error: Codegen("No compiler compiled into executable")
```

pglite-oxide uses a headless Wasmer engine that can only load pre-compiled native
(AOT) artifacts. Every bundled extension in pglite-oxide ships a corresponding
`.bin.zst` AOT artifact in the `pglite-oxide-aot-*` crates. PostGIS is **not yet
bundled** — there is no `postgis-llvm-opta.bin.zst` in those crates.

This is the same blocker tracked in pglite-oxide's upstream catalog:

> Requires a pinned WASIX geospatial dependency stack and PostGIS
> configure/install-delta packaging before smoke.

The WASIX geospatial dependency stack is now built (this repo). The remaining
step is to integrate PostGIS into the pglite-oxide xtask build, produce the AOT
artifact (`postgis-llvm-opta.bin.zst` + `postgis_topology-llvm-opta.bin.zst`),
and add them to a new release of `pglite-oxide-aot-*`.

Once that upstream work lands, this harness should pass without modification.
