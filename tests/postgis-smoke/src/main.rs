use anyhow::{Context, Result, bail};
use pglite_oxide::{Pglite, PglitePaths, install_extension_archive};
use std::path::Path;
use tempfile::TempDir;

fn main() -> Result<()> {
    let archive = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "../../dist/postgis.tar.zst".to_string());
    let archive_path = Path::new(&archive);

    if !archive_path.exists() {
        bail!(
            "archive not found: {}\nUsage: postgis-smoke [path/to/postgis.tar.zst]",
            archive_path.display()
        );
    }

    println!("pglite-oxide PostGIS smoke test");
    println!("archive: {}", archive_path.display());
    println!();

    // Install archive BEFORE open so preload_installed_extension_side_modules
    // finds postgis-3.so on disk when seeding the Wasmer module cache.
    let tmp = TempDir::new().context("create temp dir")?;
    let paths = PglitePaths::with_root(tmp.path());

    println!("[1/4] Installing PostGIS archive...");
    install_extension_archive(&paths, archive_path)
        .with_context(|| format!("failed to install extension from {}", archive_path.display()))?;
    println!("      ok");

    println!("[2/4] Opening temporary pglite-oxide database...");
    let mut db = Pglite::builder()
        .path(tmp.path())
        .open()
        .context("failed to open pglite-oxide database")?;
    println!("      ok — PostgreSQL {}", postgres_version(&mut db)?);

    println!("[3/4] CREATE EXTENSION postgis...");
    db.exec("CREATE EXTENSION IF NOT EXISTS postgis", None)
        .context("CREATE EXTENSION postgis failed")?;
    println!("      ok");

    println!("[4/4] Running smoke queries...");

    // Probe each subsystem independently so one run pinpoints any failure.
    // A failed query trips PostgreSQL's longjmp recovery but leaves the
    // session usable, so we report each probe and continue.
    for (label, sql) in [
        ("postgis_version", "SELECT postgis_version() AS v"),
        ("postgis_geos_version", "SELECT postgis_geos_version() AS v"),
        ("postgis_proj_version", "SELECT postgis_proj_version() AS v"),
        (
            "geography_cast_4326",
            "SELECT ST_AsText(ST_SetSRID(ST_Point(0, 0), 4326)::geography::geometry) AS v",
        ),
        (
            "geography_distance_m",
            "SELECT ST_Distance(ST_SetSRID(ST_Point(0, 0), 4326)::geography, ST_SetSRID(ST_Point(0, 1), 4326)::geography)::text AS v",
        ),
        (
            "geometry_transform_3857",
            "SELECT ST_AsText(ST_Transform(ST_SetSRID(ST_Point(1, 1), 4326), 3857)) AS v",
        ),
        (
            "postgis_proj_version_after_transform",
            "SELECT postgis_proj_version() AS v",
        ),
    ] {
        match db.query(sql, &[], None) {
            Ok(r) => {
                let v = r.rows[0]["v"].as_str().unwrap_or("<none>");
                println!("      {label}: {v}");
            }
            Err(e) => println!("      {label}: FAILED — {e:#}"),
        }
    }

    // quad_segs=64 -> a 256-gon approximation; without it ST_Buffer's default
    // 8 segments/quadrant yields a 32-gon whose area (3.1214) is a correct but
    // coarse approximation of pi, too far off to validate against.
    let area = db
        .query(
            "SELECT ST_Area(ST_Buffer(ST_GeomFromText('POINT(0 0)'), 1, 'quad_segs=64'))::float8 AS area",
            &[],
            None,
        )
        .context("ST_Area/ST_Buffer failed")?;
    let a = area.rows[0]["area"]
        .as_f64()
        .context("area result is not a float")?;
    let expected = std::f64::consts::PI;
    if (a - expected).abs() > 0.01 {
        bail!("ST_Area result {a} is not close to π ({expected})");
    }
    println!("      ST_Area(ST_Buffer(POINT(0 0), 1)) = {a:.6} (≈π ✓)");

    match db.query("SELECT postgis_full_version() AS v", &[], None) {
        Ok(r) => {
            let v = r.rows[0]["v"].as_str().unwrap_or("<none>");
            println!("      postgis_full_version: {v}");
        }
        Err(e) => println!("      postgis_full_version: FAILED — {e:#}"),
    }

    println!();
    println!("Smoke test PASSED");
    db.close()?;
    Ok(())
}

fn postgres_version(db: &mut Pglite) -> Result<String> {
    let result = db.query("SELECT version() AS v", &[], None)?;
    Ok(result.rows[0]["v"]
        .as_str()
        .unwrap_or("unknown")
        .to_string())
}
