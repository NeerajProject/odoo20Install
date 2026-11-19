#!/usr/bin/env bash
#=============================================================================
# fix_odoo20_assets.sh - fixes the Odoo 20 browser error:
#   "Cannot destructure property 'TourInteractive' of
#    'odoo.loader.modules.get(...)' as it is undefined"
#
# Works with the stack created by install_odoo20_single.sh
#
# Usage:  sudo bash fix_odoo20_assets.sh
# Options (env vars):
#   BASE_DIR=/opt/odoo20-docker   project folder
#   DB_NAME=odoo                  database (default: read from odoo.conf)
#   UPDATE=1                      also run: -u web,web_tour  (module update)
#   UPDATE_ALL=1                  run: -u all  (use if you rebuilt on 'master')
#   DISABLE_TOURS=1               turn off onboarding tours for all users
#=============================================================================
set -Eeuo pipefail
trap 'echo -e "\033[0;31m[x]\033[0m Failed at line $LINENO" >&2' ERR

BASE_DIR="${BASE_DIR:-/opt/odoo20-docker}"
UPDATE="${UPDATE:-0}"
UPDATE_ALL="${UPDATE_ALL:-0}"
DISABLE_TOURS="${DISABLE_TOURS:-0}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*" >&2; }
die()  { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0"
[[ -d "${BASE_DIR}" ]] || die "Project folder not found: ${BASE_DIR} (set BASE_DIR=...)"
cd "${BASE_DIR}"
[[ -f docker-compose.yml ]] || die "docker-compose.yml not found in ${BASE_DIR}"

DC="docker compose"

# --- find config file and database name --------------------------------------
CONF_FILE="$(sed -nE 's/^ODOO_CONF_FILE=//p' .env 2>/dev/null | head -1)"
CONF_FILE="${CONF_FILE:-odoo.conf}"
[[ -f "${CONF_FILE}" ]] || die "Config file ${CONF_FILE} not found in ${BASE_DIR}"

if [[ -z "${DB_NAME:-}" ]]; then
    DB_NAME="$(sed -nE 's/^db_name *= *//p' "${CONF_FILE}" | head -1 | tr -d '[:space:]')"
fi
[[ -n "${DB_NAME}" ]] || die "Could not detect the database. Run: DB_NAME=yourdb sudo -E bash $0"
[[ "${DB_NAME}" =~ ^[A-Za-z0-9_]+$ ]] || die "Invalid DB_NAME: ${DB_NAME}"
log "Project: ${BASE_DIR} | Database: ${DB_NAME} | Config: ${CONF_FILE}"

# --- 1. make sure the database is running -------------------------------------
log "Starting PostgreSQL..."
$DC up -d --wait db

# --- 2. stop Odoo/Nginx while fixing ------------------------------------------
log "Stopping Odoo and Nginx..."
$DC stop odoo nginx >/dev/null 2>&1 || true

# --- 3. purge cached asset bundles --------------------------------------------
log "Deleting cached web assets from the database..."
DELETED="$($DC exec -T db psql -U odoo -d "${DB_NAME}" -tAc \
    "WITH d AS (DELETE FROM ir_attachment WHERE url LIKE '/web/assets/%' RETURNING 1) SELECT count(*) FROM d;" \
    | tr -d '[:space:]')"
log "Removed ${DELETED} cached asset attachment(s)."

# --- 4. optional module update (also regenerates assets) -----------------------
if [[ "${UPDATE_ALL}" == "1" ]]; then
    log "Updating ALL modules (this can take several minutes)..."
    $DC run --rm -T odoo -c "/etc/odoo/${CONF_FILE}" -d "${DB_NAME}" -u all \
        --stop-after-init --workers=0
elif [[ "${UPDATE}" == "1" ]]; then
    log "Updating modules web and web_tour..."
    $DC run --rm -T odoo -c "/etc/odoo/${CONF_FILE}" -d "${DB_NAME}" -u web,web_tour \
        --stop-after-init --workers=0
fi

# --- 5. optional: disable onboarding tours --------------------------------------
if [[ "${DISABLE_TOURS}" == "1" ]]; then
    log "Disabling onboarding tours for all users..."
    OUT="$(cat <<'PYEOF' | $DC run --rm -T odoo shell -c "/etc/odoo/${CONF_FILE}" -d "${DB_NAME}" --workers=0 2>&1 || true
if 'tour_enabled' in env['res.users']._fields:
    env['res.users'].with_context(active_test=False).search([]).write({'tour_enabled': False})
    env.cr.commit()
    print('TOURS_DISABLED')
else:
    print('TOURS_FIELD_MISSING')
PYEOF
)"
    if grep -q TOURS_DISABLED <<<"${OUT}"; then
        log "Tours disabled."
    else
        warn "Field 'tour_enabled' not found - skipped (not an error)."
    fi
fi

# --- 6. start everything -------------------------------------------------------
log "Starting Odoo and Nginx..."
$DC up -d
$DC restart nginx >/dev/null

PORT="$(sed -nE 's/^HTTP_PORT=//p' .env | head -1)"; PORT="${PORT:-80}"
ok=0
log "Waiting for Odoo on port ${PORT} (up to 3 minutes)..."
for _ in $(seq 1 60); do
    if curl -sf -o /dev/null "http://127.0.0.1:${PORT}/web/login"; then ok=1; break; fi
    sleep 3
done
if [[ ${ok} -ne 1 ]]; then
    warn "Odoo is not answering. Last log lines:"
    $DC logs --tail 60 odoo nginx || true
    die "Odoo did not come up."
fi

# --- 7. warm up: force the asset bundle to be rebuilt once ----------------------
log "Rebuilding asset bundles (first page load)..."
curl -s -o /dev/null "http://127.0.0.1:${PORT}/web/login" || true
curl -s -o /dev/null "http://127.0.0.1:${PORT}/web" || true

echo
echo "=============================================================="
echo "  Done. Now in your browser:"
echo "    1. Open the site in a PRIVATE window, or"
echo "    2. Clear site data, then hard-refresh (Ctrl+Shift+R)"
echo "--------------------------------------------------------------"
echo "  Still failing? Try, in order:"
echo "    sudo UPDATE=1 bash $0"
echo "    sudo UPDATE_ALL=1 bash $0        (if you use ODOO_BRANCH=master)"
echo "    sudo DISABLE_TOURS=1 bash $0"
echo "  Logs: cd ${BASE_DIR} && docker compose logs -f odoo"
echo "=============================================================="
