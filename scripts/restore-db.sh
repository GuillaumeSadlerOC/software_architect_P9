#!/usr/bin/env bash
# =============================================================================
# PostgreSQL restore script for Orion MicroCRM.
#
# Stops the backend (to prevent concurrent writes), drops and recreates the
# target database from a dump file, restarts the backend, and verifies the
# application health endpoint responds.
#
# USAGE:
#   ./scripts/restore-db.sh ./backups/microcrm-20260421-020000.dump
#
# SAFETY:
#   - Requires an explicit dump file argument (no "latest" guessing).
#   - Prompts for confirmation unless FORCE=1 is set (for automation).
#   - Operates only on the configured CONTAINER_NAME — no accidental prod hit.
# =============================================================================

set -euo pipefail

# -- Configuration -----------------------------------------------------------
CONTAINER_NAME="${CONTAINER_NAME:-orion-postgres}"
DB_NAME="${DB_NAME:-microcrm}"
DB_USER="${DB_USER:-microcrm}"
BACK_SERVICE="${BACK_SERVICE:-back}"
HEALTH_URL="${HEALTH_URL:-http://localhost:8080/actuator/health}"

# -- Argument check ----------------------------------------------------------
if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <dump-file>" >&2
  echo "Example: $0 ./backups/microcrm-20260421-020000.dump" >&2
  exit 2
fi

DUMP_FILE="$1"
if [[ ! -f "${DUMP_FILE}" ]]; then
  echo "[restore] ERROR: dump file not found: ${DUMP_FILE}" >&2
  exit 1
fi

# -- Confirmation ------------------------------------------------------------
if [[ "${FORCE:-0}" != "1" ]]; then
  echo "[restore] About to RESTORE ${DUMP_FILE} into database '${DB_NAME}'."
  echo "[restore] This will DROP the current database content."
  read -r -p "[restore] Type 'yes' to proceed: " confirm
  [[ "${confirm}" == "yes" ]] || { echo "[restore] Aborted."; exit 0; }
fi

# -- Stop the backend (prevent concurrent writes) ----------------------------
echo "[restore] Stopping backend service '${BACK_SERVICE}'..."
docker compose stop "${BACK_SERVICE}" || true

# -- Drop + recreate database ------------------------------------------------
echo "[restore] Dropping and recreating database '${DB_NAME}'..."
docker exec -i "${CONTAINER_NAME}" psql -U "${DB_USER}" -d postgres -c \
  "DROP DATABASE IF EXISTS ${DB_NAME};"
docker exec -i "${CONTAINER_NAME}" psql -U "${DB_USER}" -d postgres -c \
  "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};"

# -- Restore -----------------------------------------------------------------
echo "[restore] Loading dump..."
docker exec -i "${CONTAINER_NAME}" \
  pg_restore \
    --username="${DB_USER}" \
    --dbname="${DB_NAME}" \
    --no-owner \
    --verbose \
  < "${DUMP_FILE}"

# -- Restart the backend -----------------------------------------------------
echo "[restore] Starting backend service '${BACK_SERVICE}'..."
docker compose up -d "${BACK_SERVICE}"

# -- Smoke-test the health endpoint -----------------------------------------
echo "[restore] Waiting up to 60s for /actuator/health to return UP..."
for attempt in $(seq 1 30); do
  if curl -fsS "${HEALTH_URL}" | grep -q '"status":"UP"'; then
    echo "[restore] Health OK."
    exit 0
  fi
  sleep 2
done

echo "[restore] WARNING: health endpoint did not return UP within 60s." >&2
echo "[restore] The restore completed, but the backend may need manual inspection." >&2
exit 1
