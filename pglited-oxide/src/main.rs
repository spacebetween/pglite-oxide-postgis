//! pglited-oxide: an embedded PostgreSQL TCP server that speaks the Postgres
//! wire protocol, backed by `pglite-oxide` (PostgreSQL 17.5 compiled to WASIX,
//! running under Wasmer). Drop-in replacement for filipecabaco/pglited used by
//! ex_pglite.
//!
//! Usage:
//!     pglited-oxide <data_dir> <tcp_port> [--multiplexer queue]
//!
//! `data_dir` may be a real path (persistent), an existing tempdir, or a
//! `memory://...` URI (treated as a fresh tempdir, contents discarded on exit).
//! When listening, emits a single JSON line on stdout:
//!     {"id":"ready","success":true,"port":<port>,"multiplexer":"<mode>"}
//! and a matching `{"id":"ready","success":false,"error":...}` on failure.
//!
//! Extensions bundled: citext, pgvector ("vector"), postgis, postgis_topology.
//! Postgres connection caveat: pglite-oxide's wire-protocol proxy serializes
//! all sessions onto a single backend thread. Configure your client pool with
//! `pool_size: 1`.

use anyhow::{Context, Result};
use pglite_oxide::{
    extensions::{CITEXT, VECTOR},
    install_extension_bytes, PglitePaths, PgliteServer,
};
use serde_json::json;
use std::io::Write;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::process;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tempfile::TempDir;

// Embedded at compile time so the binary is fully self-contained.
// `pglite-oxide-assets` 0.5.0 does not ship PostGIS bytes; install via
// `install_extension_bytes` before the server opens.
const POSTGIS_ARCHIVE: &[u8] = include_bytes!("../../dist/postgis.tar.zst");
const TSEARCH_DATA: &[(&str, &[u8])] = &[
    (
        "danish.stop",
        include_bytes!("../assets/tsearch_data/danish.stop"),
    ),
    (
        "dutch.stop",
        include_bytes!("../assets/tsearch_data/dutch.stop"),
    ),
    (
        "english.stop",
        include_bytes!("../assets/tsearch_data/english.stop"),
    ),
    (
        "finnish.stop",
        include_bytes!("../assets/tsearch_data/finnish.stop"),
    ),
    (
        "french.stop",
        include_bytes!("../assets/tsearch_data/french.stop"),
    ),
    (
        "german.stop",
        include_bytes!("../assets/tsearch_data/german.stop"),
    ),
    (
        "hungarian.stop",
        include_bytes!("../assets/tsearch_data/hungarian.stop"),
    ),
    (
        "italian.stop",
        include_bytes!("../assets/tsearch_data/italian.stop"),
    ),
    (
        "nepali.stop",
        include_bytes!("../assets/tsearch_data/nepali.stop"),
    ),
    (
        "norwegian.stop",
        include_bytes!("../assets/tsearch_data/norwegian.stop"),
    ),
    (
        "portuguese.stop",
        include_bytes!("../assets/tsearch_data/portuguese.stop"),
    ),
    (
        "russian.stop",
        include_bytes!("../assets/tsearch_data/russian.stop"),
    ),
    (
        "spanish.stop",
        include_bytes!("../assets/tsearch_data/spanish.stop"),
    ),
    (
        "swedish.stop",
        include_bytes!("../assets/tsearch_data/swedish.stop"),
    ),
    (
        "turkish.stop",
        include_bytes!("../assets/tsearch_data/turkish.stop"),
    ),
];

fn main() {
    if let Err(err) = run() {
        emit_ready_failure(&err);
        eprintln!("pglited-oxide: fatal: {err:#}");
        process::exit(1);
    }
}

fn run() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (data_arg, port, multiplexer, init_sql_file) = parse_args(&args)?;

    // Resolve the storage root.
    //   memory://... -> fresh temp dir, dropped on exit
    //   anything else -> persistent path on disk
    let (root, _temp_guard): (PathBuf, Option<TempDir>) = if let Some(rest) =
        data_arg.strip_prefix("memory://")
    {
        let parent = std::env::temp_dir().join("pglited-oxide");
        std::fs::create_dir_all(&parent).ok();
        let prefix = if rest.is_empty() {
            "session-".to_string()
        } else {
            format!("{}-", sanitize_prefix(rest))
        };
        let tmp = tempfile::Builder::new()
            .prefix(&prefix)
            .tempdir_in(&parent)
            .context("create memory:// temp dir")?;
        (tmp.path().to_path_buf(), Some(tmp))
    } else {
        let p = PathBuf::from(&data_arg);
        std::fs::create_dir_all(&p).with_context(|| format!("create data_dir {}", p.display()))?;
        (p, None)
    };

    let addr: SocketAddr = format!("127.0.0.1:{port}")
        .parse()
        .with_context(|| format!("invalid port {port}"))?;

    // Install PostGIS .so files into the pgroot BEFORE opening the server
    // so the backend can dlopen them when CREATE EXTENSION runs. Required
    // because the published `pglite-oxide-assets` 0.5.0 does not bundle
    // PostGIS source archives.
    let paths = PglitePaths::with_root(&root);
    install_extension_bytes(&paths, POSTGIS_ARCHIVE).context("install bundled PostGIS archive")?;
    install_tsearch_data(&paths).context("install bundled text search data")?;

    // CITEXT and VECTOR are registered with the builder so PgliteServer's
    // proxy re-runs `CREATE EXTENSION IF NOT EXISTS …` for them on every new
    // client connection. POSTGIS cannot use the same mechanism because
    // install_missing_extension_archives() (called by the proxy at backend
    // open) looks up the archive bytes in pglite_oxide_assets and fails for
    // POSTGIS. We bootstrap POSTGIS once via a self-connect below.
    let server = PgliteServer::builder()
        .path(&root)
        .tcp(addr)
        .extension(CITEXT)
        .extension(VECTOR)
        .username("postgres")
        .database("postgres")
        .start()
        .context("PgliteServer::start failed")?;

    // One-shot self-connect that runs CREATE EXTENSION postgis and (if
    // requested) the init-sql-file. After this, postgis types are in
    // pg_type and every subsequent Postgrex connection sees them at
    // type-cache build time.
    bootstrap(addr, init_sql_file.as_deref())
        .context("bootstrap PostGIS / seed via self-connect")?;

    let bound_port = server.tcp_addr().map(|a| a.port()).unwrap_or(port);

    // ex_pglite waits for this JSON line on stdout before declaring the port
    // ready. Match the original pglited shape so consumers don't have to
    // special-case our wrapper.
    let ready = if let Some(mode) = multiplexer.as_deref() {
        json!({
            "id": "ready",
            "success": true,
            "port": bound_port,
            "multiplexer": mode,
            "database_url": server.database_url(),
        })
    } else {
        json!({
            "id": "ready",
            "success": true,
            "port": bound_port,
            "database_url": server.database_url(),
        })
    };
    println!("{ready}");
    std::io::stdout().flush().ok();

    let shutdown = Arc::new(AtomicBool::new(false));
    {
        let shutdown = Arc::clone(&shutdown);
        ctrlc::set_handler(move || shutdown.store(true, Ordering::SeqCst))
            .context("install signal handler")?;
    }

    // Park until SIGINT/SIGTERM, then shut down cleanly. We poll a short
    // interval rather than using park_timeout/condvar because Drop on
    // PgliteServer already performs an orderly shutdown — we just need to
    // notice the signal.
    while !shutdown.load(Ordering::SeqCst) {
        std::thread::sleep(std::time::Duration::from_millis(200));
    }

    server.shutdown().ok();
    Ok(())
}

fn parse_args(args: &[String]) -> Result<(String, u16, Option<String>, Option<PathBuf>)> {
    if args.len() < 2 {
        anyhow::bail!(
            "usage: pglited-oxide <data_dir> <tcp_port> \
             [--multiplexer <mode>] [--init-sql-file <path>]"
        );
    }
    let data_dir = args[0].clone();
    let port: u16 = args[1]
        .parse()
        .with_context(|| format!("invalid port {:?}", args[1]))?;

    let mut multiplexer = None;
    let mut init_sql_file = None;
    let mut i = 2;
    while i < args.len() {
        match args[i].as_str() {
            "--multiplexer" => {
                let val = args
                    .get(i + 1)
                    .context("--multiplexer requires a value")?
                    .clone();
                multiplexer = Some(val);
                i += 2;
            }
            "--init-sql-file" => {
                let val = args
                    .get(i + 1)
                    .context("--init-sql-file requires a path")?
                    .clone();
                init_sql_file = Some(PathBuf::from(val));
                i += 2;
            }
            other => anyhow::bail!("unknown argument: {other}"),
        }
    }
    Ok((data_dir, port, multiplexer, init_sql_file))
}

fn sanitize_prefix(s: &str) -> String {
    s.chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
                c
            } else {
                '_'
            }
        })
        .collect()
}

fn install_tsearch_data(paths: &PglitePaths) -> Result<()> {
    let dir = paths
        .mount_root()
        .join("pglite")
        .join("share")
        .join("postgresql")
        .join("tsearch_data");
    std::fs::create_dir_all(&dir)
        .with_context(|| format!("create text search data dir {}", dir.display()))?;

    for (name, contents) in TSEARCH_DATA {
        let path = dir.join(name);
        let needs_write = match std::fs::read(&path) {
            Ok(existing) => existing != *contents,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => true,
            Err(err) => return Err(err).with_context(|| format!("read {}", path.display())),
        };

        if needs_write {
            std::fs::write(&path, contents)
                .with_context(|| format!("write text search data {}", path.display()))?;
        }
    }

    Ok(())
}

/// Connects to our just-started TCP server and runs:
///   1. `CREATE EXTENSION IF NOT EXISTS postgis` (PostGIS cannot ride the
///      regular `.extension(POSTGIS)` builder path because the published
///      pglite-oxide-assets crate does not bundle its source archive).
///   2. The contents of `init_sql_file`, if provided, via `batch_execute`
///      (simple query protocol — the only Postgres protocol that supports
///      multi-statement scripts).
///
/// The proxy serializes connections onto one backend, so we wait for the
/// connection to close before returning to the main loop — otherwise we
/// would race with the first real client.
fn bootstrap(addr: SocketAddr, init_sql_file: Option<&Path>) -> Result<()> {
    let init_sql = match init_sql_file {
        Some(p) => Some(
            std::fs::read_to_string(p)
                .with_context(|| format!("read init-sql-file {}", p.display()))?,
        ),
        None => None,
    };

    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_io()
        .enable_time()
        .build()
        .context("build tokio runtime")?;

    rt.block_on(async move {
        let config = format!(
            "host={} port={} user=postgres dbname=postgres",
            addr.ip(),
            addr.port()
        );
        let (client, connection) = tokio_postgres::connect(&config, tokio_postgres::NoTls)
            .await
            .context("bootstrap: connect")?;

        let conn_handle = tokio::spawn(async move { connection.await });

        // pglite-oxide's .extension(CITEXT/VECTOR) builder calls install
        // these into pg_catalog, but pg_dump output from a normal Postgres
        // expects them in `public` (e.g. `column public.vector(384)`).
        // Re-home them in public before applying any seed. Safe to CASCADE
        // because no user objects depend on them yet.
        client
            .batch_execute(
                "DROP EXTENSION IF EXISTS vector CASCADE;\n\
                 DROP EXTENSION IF EXISTS citext CASCADE;\n\
                 CREATE EXTENSION vector WITH SCHEMA public;\n\
                 CREATE EXTENSION citext WITH SCHEMA public;\n\
                 CREATE EXTENSION IF NOT EXISTS postgis WITH SCHEMA public;",
            )
            .await
            .context("bootstrap: re-home extensions to public schema")?;

        if let Some(sql) = &init_sql {
            client
                .batch_execute(sql)
                .await
                .context("bootstrap: apply init-sql-file")?;
        }

        drop(client);
        let _ = conn_handle.await;
        Ok::<_, anyhow::Error>(())
    })
}

fn emit_ready_failure(err: &anyhow::Error) {
    let line = json!({
        "id": "ready",
        "success": false,
        "error": format!("{err:#}"),
    });
    let _ = writeln!(std::io::stdout(), "{line}");
    let _ = std::io::stdout().flush();
}
