# pglited-oxide

Standalone TCP server binary for `ex_pglite_oxide`.

This wraps `pglite-oxide`'s `PgliteServer` and embeds:

- PostgreSQL 17.5 WASIX AOT artifacts
- citext
- pgvector
- PostGIS 3.5 with GEOS and PROJ

The executable is self-contained at runtime. Consumers should normally install
prebuilt release assets through `ex_pglite_oxide`; this project exists for
maintainers who need to rebuild those assets.

## Build

```sh
cargo build --release
```

The build reads `PGLITE_OXIDE_GENERATED_AOT_DIR` from `.cargo/config.toml` and
embeds the platform-specific AOT artifacts from `../aot-artifacts`.

## CLI

```sh
pglited-oxide <data_dir> <tcp_port> [--multiplexer <mode>] [--init-sql-file <path>]
```

`memory://...` data dirs are backed by a temporary directory and discarded when
the process exits.
