#!/usr/bin/env bash
# =============================================================================
# PostgreSQL backup script for Orion MicroCRM.
#
# Dumps the app database using pg_dump in custom (binary, compressed) format
# to ./backups/, then rotates local backups older than 7 days.
#
# USAGE:
#   ./scripts/backup-db.sh              # uses defaults from .env
#   BACKUP_DIR=/mnt/nas ./scripts/backup-db.sh
#
# DESIGN:
#   - Runs pg_dump INSIDE the postgres container (no client tool required on
#     the host, and version of pg_dump always matches the server).
#   - Custom format (-Fc) is smaller than plain SQL and restorable with
#     pg_restore with parallelism and selective object support.
#   - Exit code is non-zero on any failure — suitable for cron/systemd.
# =============================================================================

set -euo pipefail

# -- Configuration -----------------------------------------------------------
CONTAINER_NAME="${CONTAINER_NAME:-orion-postgres}"
DB_NAME="${DB_NAME:-microcrm}"
DB_USER="${DB_USER:-microcrm}"
BACKUP_DIR="${BACKUP_DIR:-./backups}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"

# -- Setup -------------------------------------------------------------------
mkdir -p "${BACKUP_DIR}"
TIMESTAMP="$(date -u +%Y%m%d-%H%M%S)"
DUMP_FILE="${BACKUP_DIR}/microcrm-${TIMESTAMP}.dump"

echo "[backup] Dumping database '${DB_NAME}' from container '${CONTAINER_NAME}'..."

# -- Dump --------------------------------------------------------------------
# -Fc : custom format (compressed, restorable with pg_restore)
# --clean --if-exists : the dump includes DROP statements so a restore can
#                       safely replace existing objects without a manual drop.
docker exec -i "${CONTAINER_NAME}" \
  pg_dump \
    --username="${DB_USER}" \
    --dbname="${DB_NAME}" \
    --format=custom \
    --clean --if-exists \
    --no-owner \
    --verbose \
  > "${DUMP_FILE}"

SIZE="$(du -h "${DUMP_FILE}" | cut -f1)"
echo "[backup] Wrote ${DUMP_FILE} (${SIZE})"

# -- Rotation ----------------------------------------------------------------
echo "[backup] Rotating: keep last ${RETENTION_DAYS} days."
find "${BACKUP_DIR}" -maxdepth 1 -name 'microcrm-*.dump' -mtime "+${RETENTION_DAYS}" -print -delete

echo "[backup] Done."
