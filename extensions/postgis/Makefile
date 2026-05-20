# PostGIS PGXS Makefile
#
# This Makefile builds PostGIS as a shared module for WASIX PostgreSQL
# using the PostgreSQL Extension System (PGXS).

EXTENSION = postgis
EXTVERSION = 3.5.2

MODULE_big = postgis-3

PG_CONFIG ?= /build/pg_install/bin/pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

OBJS = \
  postgis_module.o \
  lwgeom_accum.o \
  lwgeom_btree.o \
  lwgeom_box.o \
  lwgeom_box3d.o \
  lwgeom_cache.o \
  lwgeom_dump.o \
  lwgeom_dumppoints.o \
  lwgeom_estimate.o \
  lwgeom_export.o \
  lwgeom_functions_analytic.o \
  lwgeom_functions_basic.o \
  lwgeom_functions_lrs.o \
  lwgeom_functions_temporal.o \
  lwgeom_geos.o \
  lwgeom_geos_clean.o \
  lwgeom_geos_cluster.o \
  lwgeom_geos_coverage.o \
  lwgeom_geos_node.o \
  lwgeom_geos_prepared.o \
  lwgeom_geos_relatematch.o \
  lwgeom_generate_grid.o \
  lwgeom_geography.o \
  lwgeom_geometry_out.o \
  lwgeom_in_flatgeobuf.o \
  lwgeom_in_geohash.o \
  lwgeom_in_geojson.o \
  lwgeom_in_gml.o \
  lwgeom_in_kml.o \
  lwgeom_in_mvt.o \
  lwgeom_in_twkb.o \
  lwgeom_in_wkb.o \
  lwgeom_in_wkt.o \
  lwgeom_legacy.o \
  lwgeom_ogc.o \
  lwgeom_out_flatgeobuf.o \
  lwgeom_out_geojson.o \
  lwgeom_out_gml.o \
  lwgeom_out_kml.o \
  lwgeom_out_mvt.o \
  lwgeom_out_twkb.o \
  lwgeom_out_wkb.o \
  lwgeom_out_wkt.o \
  lwgeom_out_x3d.o \
  lwgeom_overlay.o \
  lwgeom_polygon.o \
  lwgeom_rectree.o \
  lwgeom_spheroid.o \
  lwgeom_sqlmm.o \
  lwgeom_sfcgal.o \
  lwgeom_transform.o \
  lwgeom_triggers.o \
  lwgeom_window.o \
  lwgeom_wrapx.o \
  mvt.o

SHLIB_LINK = \
  -L$(WASIX_PREFIX)/lib \
  -lgeos_c \
  -lgeos \
  -lproj \
  -lsqlite3 \
  -lxml2 \
  -ljson-c \
  -lstdc++

PG_CPPFLAGS = \
  --target=wasm32-wasix \
  --sysroot=$(WASIX_SYSROOT) \
  -I$(WASIX_PREFIX)/include \
  -I$(PG_INSTALL_DIR)/include \
  -I$(PG_INSTALL_DIR)/include/server

SHLIB_LINK += -Wl,-shared

DATA = \
  postgis--3.5.2.sql \
  postgis.control

EXTRA_CLEAN = postgis--3.5.2.sql
