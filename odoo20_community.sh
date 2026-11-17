#!/usr/bin/env bash
#=============================================================================
# odoo20_community.sh
# Install Odoo 20 Community on Ubuntu 24.04 LTS + Nginx reverse proxy (:8020)
#
# Usage:   sudo bash odoo20_community.sh
# Options (environment variables):
#   NGINX_PORT=8020        public port served by Nginx
#   SERVER_NAME=_          domain name (e.g. erp.example.com) or _ for any
#   ODOO_USERS=10          expected concurrent users (workers/RAM limits are
#                          calculated from this; asked interactively if unset)
#   ODOO_WORKERS=          override calculated workers (0 = threaded mode)
#   ODOO_ADMIN_PASSWD=     master password (random if empty)
#   DB_PASSWORD=           PostgreSQL password for odoo20 (random if empty)
#=============================================================================
set -Eeuo pipefail

# ----------------------------- Configuration -------------------------------
ODOO_VERSION="20.0"
ODOO_USER="odoo20"
ODOO_HOME="/opt/odoo20"
ODOO_CONF="/etc/odoo20.conf"
ODOO_LOG_DIR="/var/log/odoo"
ODOO_LOG="${ODOO_LOG_DIR}/odoo20.log"
ODOO_SERVICE="odoo20"
ODOO_PORT="8069"             # internal Odoo HTTP port
ODOO_GEVENT_PORT="8072"      # internal Odoo websocket/longpolling port
ODOO_USERS="${ODOO_USERS:-}"
ODOO_WORKERS="${ODOO_WORKERS:-}"

NGINX_PORT="${NGINX_PORT:-8020}"
SERVER_NAME="${SERVER_NAME:-_}"
NGINX_SITE="odoo20"

DB_USER="odoo20"
DB_PASSWORD="${DB_PASSWORD:-$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24)}"
ODOO_ADMIN_PASSWD="${ODOO_ADMIN_PASSWD:-$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24)}"

WKHTML_URL="https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.jammy_amd64.deb"
WKHTML_SHA1="967390a759707337b46d1c02452e2bb6b2dc6d59"

CRED_FILE="/root/odoo20_credentials.txt"

# ------------------------------- Helpers -----------------------------------
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }
trap 'die "Failed at line $LINENO. Check the output above."' ERR

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0"

if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    [[ "${ID:-}" == "ubuntu" ]] || warn "Tested on Ubuntu 24.04 only (detected: ${PRETTY_NAME:-unknown})"
    [[ "${VERSION_ID:-}" == "24.04" ]] || warn "Ubuntu 24.04 recommended (detected: ${VERSION_ID:-unknown})"
fi

if ss -ltn "( sport = :${NGINX_PORT} )" | grep -q LISTEN; then
    die "Port ${NGINX_PORT} is already in use. Free it or set NGINX_PORT=<other>."
fi


# ---------------------- Sizing from number of users -------------------------
if [[ -z "${ODOO_USERS}" ]]; then
    if [[ -t 0 ]]; then
        read -rp "Expected number of concurrent Odoo users [10]: " ODOO_USERS
    fi
    ODOO_USERS="${ODOO_USERS:-10}"
fi
[[ "${ODOO_USERS}" =~ ^[1-9][0-9]*$ ]] || die "ODOO_USERS must be a positive integer (got '${ODOO_USERS}')"

CPU_COUNT="$(nproc)"
RAM_MB="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"

if [[ -z "${ODOO_WORKERS}" ]]; then
    # Rule of thumb: 1 worker serves ~6 concurrent users
    ODOO_WORKERS=$(( (ODOO_USERS + 5) / 6 ))
    (( ODOO_WORKERS < 2 )) && ODOO_WORKERS=2
    MAX_BY_CPU=$(( CPU_COUNT * 2 + 1 ))
    MAX_BY_RAM=$(( (RAM_MB - 1024) / 600 ))   # ~600 MB per worker, 1 GB for OS/PostgreSQL
    (( MAX_BY_RAM < 2 )) && MAX_BY_RAM=2
    if (( ODOO_WORKERS > MAX_BY_CPU )); then
        warn "${ODOO_USERS} users need ${ODOO_WORKERS} workers but ${CPU_COUNT} CPU(s) support ${MAX_BY_CPU}. Capping."
        ODOO_WORKERS=${MAX_BY_CPU}
    fi
    if (( ODOO_WORKERS > MAX_BY_RAM )); then
        warn "${RAM_MB} MB RAM supports about ${MAX_BY_RAM} workers. Capping."
        ODOO_WORKERS=${MAX_BY_RAM}
    fi
fi
[[ "${ODOO_WORKERS}" =~ ^[0-9]+$ ]] || die "ODOO_WORKERS must be a number"

# Per-worker memory limits: use up to ~70% of RAM across workers + cron
PER_WORKER_MB=$(( RAM_MB * 70 / 100 / (ODOO_WORKERS + 2) ))
(( PER_WORKER_MB > 2048 )) && PER_WORKER_MB=2048
(( PER_WORKER_MB < 256 ))  && PER_WORKER_MB=256
MEM_SOFT=$(( PER_WORKER_MB * 1024 * 1024 ))
MEM_HARD=$(( MEM_SOFT * 5 / 4 ))

log "Sizing: ${ODOO_USERS} users | ${CPU_COUNT} CPU | ${RAM_MB} MB RAM -> workers=${ODOO_WORKERS}, soft limit=${PER_WORKER_MB} MB"

export DEBIAN_FRONTEND=noninteractive

# ---------------------------- 1. System update ------------------------------
log "Updating system packages..."
apt-get update -y
apt-get upgrade -y

# --------------------------- 2. Base dependencies ---------------------------
log "Installing build tools and libraries..."
apt-get install -y \
    python3-pip python3-venv python3-dev python3-wheel \
    git curl wget ca-certificates openssl \
    build-essential libxml2-dev libxslt1-dev zlib1g-dev \
    libsasl2-dev libldap2-dev libssl-dev libffi-dev \
    libjpeg-dev libpq-dev liblcms2-dev libblas-dev \
    libatlas-base-dev libopenjp2-7-dev libtiff5-dev libwebp-dev \
    npm node-less nodejs fail2ban ufw

if [[ ! -e /usr/bin/node && -x /usr/bin/nodejs ]]; then
    ln -s /usr/bin/nodejs /usr/bin/node
fi

log "Installing Less (global npm)..."
npm install -g less less-plugin-clean-css

systemctl enable --now fail2ban

# ----------------------------- 3. PostgreSQL --------------------------------
log "Installing PostgreSQL..."
apt-get install -y postgresql postgresql-client
systemctl enable --now postgresql

log "Creating PostgreSQL role '${DB_USER}'..."
if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1; then
    warn "Role ${DB_USER} exists - updating its password."
    sudo -u postgres psql -c "ALTER ROLE ${DB_USER} WITH LOGIN CREATEDB PASSWORD '${DB_PASSWORD}';"
else
    sudo -u postgres psql -c "CREATE ROLE ${DB_USER} WITH LOGIN CREATEDB NOSUPERUSER NOCREATEROLE PASSWORD '${DB_PASSWORD}';"
fi

# --------------------------- 4. System user ---------------------------------
if ! id "${ODOO_USER}" &>/dev/null; then
    log "Creating system user '${ODOO_USER}'..."
    adduser --system --quiet --shell=/bin/bash --home="${ODOO_HOME}" --group "${ODOO_USER}"
else
    warn "User ${ODOO_USER} already exists."
fi

# --------------------------- 5. Odoo source ---------------------------------
mkdir -p "${ODOO_HOME}"
chown "${ODOO_USER}:${ODOO_USER}" "${ODOO_HOME}"

if [[ -d "${ODOO_HOME}/.git" ]]; then
    warn "Odoo source already present in ${ODOO_HOME} - skipping clone."
else
    log "Cloning Odoo ${ODOO_VERSION} Community..."
    sudo -u "${ODOO_USER}" git clone https://github.com/odoo/odoo.git \
        --depth 1 --branch "${ODOO_VERSION}" --single-branch "${ODOO_HOME}"
fi

# Custom addons directory
mkdir -p "${ODOO_HOME}/custom-addons"
chown "${ODOO_USER}:${ODOO_USER}" "${ODOO_HOME}/custom-addons"

# --------------------------- 6. Python venv ---------------------------------
# Odoo 20 needs Python >= 3.12 (Ubuntu 24.04 ships it; older releases do not)
py_ok() { "$1" -c 'import sys; sys.exit(0 if sys.version_info >= (3,12) else 1)' 2>/dev/null; }

PYTHON_BIN=""
for cand in python3.13 python3.12 python3; do
    if command -v "${cand}" &>/dev/null && py_ok "$(command -v "${cand}")"; then
        PYTHON_BIN="$(command -v "${cand}")"
        break
    fi
done

if [[ -z "${PYTHON_BIN}" ]]; then
    if [[ "${ID:-}" == "ubuntu" ]]; then
        warn "System Python is older than 3.12 - installing Python 3.12 from the deadsnakes PPA..."
        apt-get install -y software-properties-common
        add-apt-repository -y ppa:deadsnakes/ppa
        apt-get update -y
        apt-get install -y python3.12 python3.12-venv python3.12-dev
        PYTHON_BIN="$(command -v python3.12)"
    else
        die "Python >= 3.12 is required but not available on ${PRETTY_NAME:-this OS}. Use Ubuntu 24.04 or install Python 3.12 manually."
    fi
fi
log "Using Python: ${PYTHON_BIN} ($(${PYTHON_BIN} --version))"

log "Creating Python virtual environment and installing requirements..."
# Recreate the venv if it was built with an older Python
if [[ -x "${ODOO_HOME}/venv/bin/python" ]] && ! py_ok "${ODOO_HOME}/venv/bin/python"; then
    warn "Existing venv uses an old Python - recreating it."
    rm -rf "${ODOO_HOME}/venv"
fi
if [[ ! -d "${ODOO_HOME}/venv" ]]; then
    sudo -u "${ODOO_USER}" "${PYTHON_BIN}" -m venv "${ODOO_HOME}/venv"
fi
sudo -u "${ODOO_USER}" "${ODOO_HOME}/venv/bin/pip" install --upgrade pip wheel
sudo -u "${ODOO_USER}" "${ODOO_HOME}/venv/bin/pip" install -r "${ODOO_HOME}/requirements.txt"

# --------------------------- 7. wkhtmltopdf ---------------------------------
if command -v wkhtmltopdf &>/dev/null && wkhtmltopdf --version 2>/dev/null | grep -q "0.12.6.1"; then
    warn "wkhtmltopdf 0.12.6.1 already installed."
else
    log "Installing wkhtmltopdf..."
    TMP_DEB="$(mktemp --suffix=.deb)"
    wget -qO "${TMP_DEB}" "${WKHTML_URL}"
    echo "${WKHTML_SHA1}  ${TMP_DEB}" | sha1sum -c - || die "wkhtmltopdf checksum mismatch"
    apt-get install -y "${TMP_DEB}" || { apt-get install -f -y; apt-get install -y "${TMP_DEB}"; }
    rm -f "${TMP_DEB}"
fi

# --------------------------- 8. Odoo config ---------------------------------
log "Writing ${ODOO_CONF}..."
mkdir -p "${ODOO_LOG_DIR}"
chown "${ODOO_USER}:root" "${ODOO_LOG_DIR}"

cat > "${ODOO_CONF}" <<EOF
[options]
admin_passwd = ${ODOO_ADMIN_PASSWD}
db_host = localhost
db_port = 5432
db_user = ${DB_USER}
db_password = ${DB_PASSWORD}
addons_path = ${ODOO_HOME}/addons,${ODOO_HOME}/custom-addons
logfile = ${ODOO_LOG}

; Only listen locally - Nginx is the public entry point
http_interface = 127.0.0.1
http_port = ${ODOO_PORT}
gevent_port = ${ODOO_GEVENT_PORT}

; Required when running behind a reverse proxy
proxy_mode = True

workers = ${ODOO_WORKERS}
max_cron_threads = 1
limit_memory_soft = ${MEM_SOFT}
limit_memory_hard = ${MEM_HARD}
limit_time_cpu = 600
limit_time_real = 1200
list_db = True
EOF
chown "${ODOO_USER}:" "${ODOO_CONF}"
chmod 640 "${ODOO_CONF}"

# --------------------------- 9. systemd service -----------------------------
log "Creating systemd service..."
cat > "/etc/systemd/system/${ODOO_SERVICE}.service" <<EOF
[Unit]
Description=Odoo 20 Community
Documentation=https://www.odoo.com
After=network.target postgresql.service
Wants=postgresql.service

[Service]
Type=simple
User=${ODOO_USER}
Group=${ODOO_USER}
ExecStart=${ODOO_HOME}/venv/bin/python3 ${ODOO_HOME}/odoo-bin -c ${ODOO_CONF}
Restart=on-failure
RestartSec=5
KillMode=mixed
SyslogIdentifier=${ODOO_SERVICE}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${ODOO_SERVICE}"
systemctl restart "${ODOO_SERVICE}"

# --------------------------- 10. Nginx --------------------------------------
log "Installing and configuring Nginx (port ${NGINX_PORT})..."
apt-get install -y nginx

cat > "/etc/nginx/sites-available/${NGINX_SITE}" <<EOF
# Odoo 20 reverse proxy - listens on ${NGINX_PORT}

upstream odoo20_backend {
    server 127.0.0.1:${ODOO_PORT};
}

upstream odoo20_websocket {
    server 127.0.0.1:${ODOO_GEVENT_PORT};
}

map \$http_upgrade \$odoo20_connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen ${NGINX_PORT};
    listen [::]:${NGINX_PORT};
    server_name ${SERVER_NAME};

    access_log /var/log/nginx/odoo20.access.log;
    error_log  /var/log/nginx/odoo20.error.log;

    client_max_body_size 200m;

    proxy_read_timeout    720s;
    proxy_connect_timeout 720s;
    proxy_send_timeout    720s;

    proxy_set_header Host              \$host:\$server_port;
    proxy_set_header X-Real-IP         \$remote_addr;
    proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Forwarded-Host  \$host;

    # Odoo websocket (live chat, bus, notifications)
    location /websocket {
        proxy_pass http://odoo20_websocket;
        proxy_http_version 1.1;
        proxy_set_header Upgrade    \$http_upgrade;
        proxy_set_header Connection \$odoo20_connection_upgrade;
        proxy_set_header Host       \$host:\$server_port;
        proxy_set_header X-Real-IP  \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 3600s;
    }

    # Main application
    location / {
        proxy_pass http://odoo20_backend;
        proxy_redirect off;
    }

    # Cache static files
    location ~* /web/static/ {
        proxy_cache_valid 200 90m;
        proxy_buffering on;
        expires 864000;
        proxy_pass http://odoo20_backend;
    }

    # Compression
    gzip on;
    gzip_min_length 1100;
    gzip_buffers 4 32k;
    gzip_types text/css text/less text/plain text/xml application/xml
               application/json application/javascript application/pdf image/jpeg image/png;
    gzip_vary on;
}
EOF

ln -sf "/etc/nginx/sites-available/${NGINX_SITE}" "/etc/nginx/sites-enabled/${NGINX_SITE}"

nginx -t
systemctl enable nginx
systemctl restart nginx

# --------------------------- 11. Firewall -----------------------------------
if ufw status | grep -q "Status: active"; then
    log "UFW is active - opening port ${NGINX_PORT}/tcp..."
    ufw allow "${NGINX_PORT}/tcp"
else
    warn "UFW is inactive. If you enable it, run: ufw allow OpenSSH && ufw allow ${NGINX_PORT}/tcp"
fi

# --------------------------- 12. Verify -------------------------------------
log "Waiting for Odoo to start..."
for i in {1..30}; do
    if curl -s -o /dev/null "http://127.0.0.1:${ODOO_PORT}/web/login"; then
        break
    fi
    sleep 3
done

HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${NGINX_PORT}/web/login" || true)"
SERVER_IP="$(hostname -I | awk '{print $1}')"

# --------------------------- 13. Save credentials ---------------------------
umask 077
cat > "${CRED_FILE}" <<EOF
Odoo 20 Community - installation details
----------------------------------------
URL (via Nginx)       : http://${SERVER_IP}:${NGINX_PORT}
Odoo internal         : http://127.0.0.1:${ODOO_PORT}
Expected users        : ${ODOO_USERS}
Odoo workers          : ${ODOO_WORKERS}
Master (admin) pass   : ${ODOO_ADMIN_PASSWD}
PostgreSQL user       : ${DB_USER}
PostgreSQL password   : ${DB_PASSWORD}
Config file           : ${ODOO_CONF}
Log file              : ${ODOO_LOG}
Custom addons dir     : ${ODOO_HOME}/custom-addons
Nginx site            : /etc/nginx/sites-available/${NGINX_SITE}
EOF

echo
echo "=============================================================="
if [[ "${HTTP_CODE}" =~ ^(200|303)$ ]]; then
    log "Odoo 20 is installed and reachable through Nginx."
else
    warn "Nginx answered with HTTP ${HTTP_CODE}. Odoo may still be starting."
    warn "Check: journalctl -u ${ODOO_SERVICE} -f   |   tail -f ${ODOO_LOG}"
fi
echo "  Users/workers: ${ODOO_USERS} users -> ${ODOO_WORKERS} workers"
echo "  Open        : http://${SERVER_IP}:${NGINX_PORT}"
echo "  Credentials : ${CRED_FILE}"
echo "  Commands    : systemctl {status|restart} ${ODOO_SERVICE}"
echo "                systemctl {status|reload} nginx"
echo "=============================================================="
