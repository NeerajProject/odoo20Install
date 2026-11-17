#!/usr/bin/env bash
#=============================================================================
# fix_odoo20.sh - repair an Odoo 20 install that fails with:
#   "Outdated python version detected, Odoo requires Python >= 3.12"
# Rebuilds the venv with Python 3.12, reinstalls requirements, restarts Odoo
# and tests both Odoo (8069) and Nginx (8020).
#
# Usage: sudo bash fix_odoo20.sh
#=============================================================================
set -Eeuo pipefail

ODOO_USER="odoo20"
ODOO_HOME="/opt/odoo20"
ODOO_SERVICE="odoo20"
ODOO_PORT="8069"
NGINX_PORT="${NGINX_PORT:-8020}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0"
[[ -f "${ODOO_HOME}/odoo-bin" ]] || die "${ODOO_HOME}/odoo-bin not found - Odoo source is missing."

. /etc/os-release
export DEBIAN_FRONTEND=noninteractive

py_ok() { "$1" -c 'import sys; sys.exit(0 if sys.version_info >= (3,12) else 1)' 2>/dev/null; }

# --- 1. Find or install Python >= 3.12 --------------------------------------
PYTHON_BIN=""
for cand in python3.13 python3.12 python3; do
    if command -v "${cand}" &>/dev/null && py_ok "$(command -v "${cand}")"; then
        PYTHON_BIN="$(command -v "${cand}")"; break
    fi
done

if [[ -z "${PYTHON_BIN}" ]]; then
    [[ "${ID}" == "ubuntu" ]] || die "Python >= 3.12 not available on ${PRETTY_NAME}. Use Ubuntu 24.04."
    log "Installing Python 3.12 (deadsnakes PPA)..."
    apt-get update -y
    apt-get install -y software-properties-common
    add-apt-repository -y ppa:deadsnakes/ppa
    apt-get update -y
    apt-get install -y python3.12 python3.12-venv python3.12-dev
    PYTHON_BIN="$(command -v python3.12)"
fi
log "Using $(${PYTHON_BIN} --version) at ${PYTHON_BIN}"

# --- 2. Build dependencies needed by requirements.txt ------------------------
log "Ensuring build libraries are installed..."
apt-get install -y build-essential libpq-dev libxml2-dev libxslt1-dev \
    libldap2-dev libsasl2-dev libssl-dev libffi-dev libjpeg-dev zlib1g-dev \
    libopenjp2-7-dev libwebp-dev liblcms2-dev

# --- 3. Rebuild the virtual environment -------------------------------------
log "Stopping Odoo and rebuilding the virtual environment..."
systemctl stop "${ODOO_SERVICE}" 2>/dev/null || true
rm -rf "${ODOO_HOME}/venv"
chown -R "${ODOO_USER}:${ODOO_USER}" "${ODOO_HOME}"
sudo -u "${ODOO_USER}" "${PYTHON_BIN}" -m venv "${ODOO_HOME}/venv"
sudo -u "${ODOO_USER}" "${ODOO_HOME}/venv/bin/pip" install --upgrade pip wheel setuptools
sudo -u "${ODOO_USER}" "${ODOO_HOME}/venv/bin/pip" install -r "${ODOO_HOME}/requirements.txt"

# --- 4. Make sure permissions are right --------------------------------------
mkdir -p /var/log/odoo
chown "${ODOO_USER}:root" /var/log/odoo
[[ -f /etc/odoo20.conf ]] && chown "${ODOO_USER}:" /etc/odoo20.conf && chmod 640 /etc/odoo20.conf

# --- 5. Restart and test -----------------------------------------------------
log "Starting Odoo..."
systemctl daemon-reload
systemctl enable "${ODOO_SERVICE}" >/dev/null 2>&1
systemctl restart "${ODOO_SERVICE}"
systemctl is-active --quiet nginx || systemctl restart nginx

log "Waiting for Odoo on port ${ODOO_PORT} (up to 2 minutes)..."
ok=0
for i in $(seq 1 40); do
    if curl -s -o /dev/null "http://127.0.0.1:${ODOO_PORT}/web/login"; then ok=1; break; fi
    sleep 3
done

if [[ ${ok} -ne 1 ]]; then
    warn "Odoo still not answering. Last log lines:"
    echo "------------------------------------------------------------"
    journalctl -u "${ODOO_SERVICE}" -n 40 --no-pager || true
    echo "------------------------------------------------------------"
    tail -n 40 /var/log/odoo/odoo20.log 2>/dev/null || true
    die "Send me the output above and I will tell you the exact fix."
fi

ODOO_CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${ODOO_PORT}/web/login")"
NGINX_CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${NGINX_PORT}/web/login" || true)"
IP="$(hostname -I | awk '{print $1}')"

echo
echo "=============================================================="
echo "  Odoo  (:${ODOO_PORT}) -> HTTP ${ODOO_CODE}"
echo "  Nginx (:${NGINX_PORT}) -> HTTP ${NGINX_CODE}"
echo "  Open  : http://${IP}:${NGINX_PORT}"
echo "=============================================================="
