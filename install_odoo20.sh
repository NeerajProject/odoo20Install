#!/usr/bin/env bash
#=============================================================================
# install_odoo20.sh - full Odoo 20 install (Ubuntu 22.04 / 24.04, Debian 13)
#
#  * Python 3.12 - 3.14 only (installs 3.12 via deadsnakes on Ubuntu if needed)
#  * PostgreSQL 16+ (Odoo 20 needs it; adds the official PGDG repo if the distro
#    ships an older one), DB role + random passwords generated automatically, Odoo from GitHub, systemd service
#  * Nginx reverse proxy with HTTPS on port 443:
#      - served on standard HTTPS port 443 (https://SERVER-IP), and http:// on 80
#        redirects to https://
#      - real domain  -> Let's Encrypt (falls back to self-signed if it fails)
#      - no domain/IP -> self-signed certificate
#
# Usage:  sudo bash install_odoo20.sh
# Options (env vars):
#   NGINX_PORT=443   SERVER_NAME=_ (or erp.example.com)   LE_EMAIL=you@example.com
#   ODOO_BRANCH=20.0  (use master if 20.0 branch does not exist yet)
#   WORKERS=2   PG_VERSION=16
#   DB_NAME=odoo   database to create (DB_NAME= to skip)   DEMO=1  load demo data
#=============================================================================
set -Eeuo pipefail
trap 'echo -e "\033[0;31m[x]\033[0m Failed at line $LINENO" >&2' ERR

ODOO_USER="odoo20"
ODOO_HOME="/opt/odoo20"
ODOO_SRC="${ODOO_HOME}/odoo"
ODOO_VENV="${ODOO_HOME}/venv"
ODOO_SERVICE="odoo20"
ODOO_CONF="/etc/odoo20.conf"
ODOO_LOG_DIR="/var/log/odoo"
ODOO_PORT="8069"
ODOO_GEVENT_PORT="8072"
ODOO_BRANCH="${ODOO_BRANCH:-20.0}"
ODOO_REPO="${ODOO_REPO:-https://github.com/odoo/odoo.git}"
WORKERS="${WORKERS:-2}"
NGINX_PORT="${NGINX_PORT:-443}"
SERVER_NAME="${SERVER_NAME:-_}"
LE_EMAIL="${LE_EMAIL:-}"
NGINX_SITE="odoo20"
CRED_FILE="/root/odoo20_credentials.txt"

PY_MIN_MINOR=12
PY_MAX_MINOR=14

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }
gen_pass() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-"${1:-24}"; }

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0"
. /etc/os-release
export DEBIAN_FRONTEND=noninteractive

#--- 1. Base packages ---------------------------------------------------------
log "Installing base packages..."
apt-get update -y
apt-get install -y git curl wget ca-certificates openssl gnupg \
    build-essential libpq-dev libxml2-dev libxslt1-dev libldap2-dev \
    libsasl2-dev libssl-dev libffi-dev libjpeg-dev zlib1g-dev \
    libopenjp2-7-dev libwebp-dev liblcms2-dev fontconfig xfonts-75dpi \
    xfonts-base postgresql-common

#--- 2. Python 3.12 - 3.14 ----------------------------------------------------
py_ok() {
    "$1" -c "import sys; sys.exit(0 if (3,${PY_MIN_MINOR}) <= sys.version_info[:2] <= (3,${PY_MAX_MINOR}) else 1)" 2>/dev/null
}
find_python() {
    local c p
    for c in python3.14 python3.13 python3.12 python3; do
        p="$(command -v "$c" 2>/dev/null || true)"
        [[ -n "$p" ]] && py_ok "$p" && { echo "$p"; return 0; }
    done
    return 1
}

PYTHON_BIN="$(find_python || true)"
if [[ -z "${PYTHON_BIN}" ]]; then
    case "${ID}" in
        ubuntu)
            log "No Python 3.12-3.14 found - installing 3.12 from deadsnakes PPA..."
            apt-get install -y software-properties-common
            add-apt-repository -y ppa:deadsnakes/ppa
            apt-get update -y
            apt-get install -y python3.12 python3.12-venv python3.12-dev
            ;;
        debian)
            apt-get install -y python3 python3-venv python3-dev || true
            ;;
        *) die "Unsupported OS ${PRETTY_NAME}. Use Ubuntu 22.04/24.04." ;;
    esac
    PYTHON_BIN="$(find_python || true)"
fi
[[ -n "${PYTHON_BIN}" ]] || die "Python 3.${PY_MIN_MINOR}-3.${PY_MAX_MINOR} is not available on ${PRETTY_NAME}. Use Ubuntu 24.04 or Debian 13."

# make sure the matching venv/dev packages exist (e.g. python3.13-venv on Ubuntu)
PYV="$(${PYTHON_BIN} -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
apt-get install -y "python${PYV}-venv" "python${PYV}-dev" 2>/dev/null \
    || apt-get install -y python3-venv python3-dev || true
log "Using Python ${PYV} at ${PYTHON_BIN}"

#--- 3. wkhtmltopdf and rtlcss (best effort) ----------------------------------
apt-get install -y wkhtmltopdf || warn "wkhtmltopdf not installed - PDF reports may not work."
# Node/npm: NodeSource's nodejs already bundles npm and conflicts with Ubuntu's
# npm package, so only install from apt when neither is present. Best effort.
if ! command -v npm &>/dev/null; then
    if command -v node &>/dev/null; then
        warn "node is installed without npm - skipping rtlcss."
    else
        apt-get install -y nodejs npm >/dev/null 2>&1 || warn "Could not install nodejs/npm - skipping rtlcss."
    fi
fi
if command -v npm &>/dev/null; then
    npm install -g rtlcss >/dev/null 2>&1 || warn "rtlcss not installed (only needed for RTL languages)."
fi

#--- 4. System user and directories -------------------------------------------
if ! id "${ODOO_USER}" &>/dev/null; then
    log "Creating system user ${ODOO_USER}..."
    adduser --system --quiet --shell /bin/bash --home "${ODOO_HOME}" --group "${ODOO_USER}"
fi
mkdir -p "${ODOO_HOME}" "${ODOO_LOG_DIR}" "${ODOO_HOME}/custom-addons"
chown -R "${ODOO_USER}:${ODOO_USER}" "${ODOO_HOME}"
chown "${ODOO_USER}:root" "${ODOO_LOG_DIR}"

#--- 5. PostgreSQL 16+ and role (random password) ----------
PG_VERSION="${PG_VERSION:-16}"
log "Configuring PostgreSQL ${PG_VERSION}..."
if ! apt-cache show "postgresql-${PG_VERSION}" &>/dev/null; then
    log "postgresql-${PG_VERSION} not in ${PRETTY_NAME} repos - adding the official PostgreSQL (PGDG) repository..."
    install -d /usr/share/postgresql-common/pgdg
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
        -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg main" \
        > /etc/apt/sources.list.d/pgdg.list
    apt-get update -y
fi
apt-get install -y "postgresql-${PG_VERSION}" "postgresql-client-${PG_VERSION}"
systemctl enable --now postgresql

# If an older cluster (e.g. 14) already existed, the new one listens on 5433 etc.
PG_PORT="$(pg_lsclusters -h 2>/dev/null | awk -v v="${PG_VERSION}" '$1==v && $2=="main" {print $3}')"
PG_PORT="${PG_PORT:-5432}"
pg_ctlcluster "${PG_VERSION}" main start 2>/dev/null || true
for _ in $(seq 1 20); do pg_isready -q -p "${PG_PORT}" && break; sleep 1; done
pg_isready -q -p "${PG_PORT}" || die "PostgreSQL ${PG_VERSION} is not accepting connections on port ${PG_PORT}."
log "PostgreSQL ${PG_VERSION} running on port ${PG_PORT}."

cd /
DB_PASSWD="$(gen_pass 24)"
if runuser -u postgres -- psql -p "${PG_PORT}" -tAc "SELECT 1 FROM pg_roles WHERE rolname='${ODOO_USER}'" | grep -q 1; then
    log "Resetting password of PostgreSQL role ${ODOO_USER}..."
    runuser -u postgres -- psql -p "${PG_PORT}" -c "ALTER ROLE ${ODOO_USER} WITH LOGIN CREATEDB PASSWORD '${DB_PASSWD}';" >/dev/null
else
    log "Creating PostgreSQL role ${ODOO_USER} with a random password..."
    runuser -u postgres -- psql -p "${PG_PORT}" -c "CREATE ROLE ${ODOO_USER} LOGIN CREATEDB PASSWORD '${DB_PASSWD}';" >/dev/null
fi

#--- 6. Odoo source -------------------------------------------------------------
if [[ ! -f "${ODOO_SRC}/odoo-bin" ]]; then
    log "Cloning Odoo (${ODOO_BRANCH})..."
    rm -rf "${ODOO_SRC}"
    runuser -u "${ODOO_USER}" -- git clone --depth 1 --branch "${ODOO_BRANCH}" "${ODOO_REPO}" "${ODOO_SRC}" \
        || die "Could not clone branch '${ODOO_BRANCH}'. If Odoo 20 is not released yet, retry with: ODOO_BRANCH=master sudo -E bash $0"
else
    log "Odoo source already present at ${ODOO_SRC}."
fi

#--- 7. Virtual environment -----------------------------------------------------
log "Building virtual environment..."
systemctl stop "${ODOO_SERVICE}" 2>/dev/null || true
if [[ -x "${ODOO_VENV}/bin/python" ]] && py_ok "${ODOO_VENV}/bin/python"; then
    log "Existing virtual environment is fine - reusing it."
else
    rm -rf "${ODOO_VENV}"
    runuser -u "${ODOO_USER}" -- "${PYTHON_BIN}" -m venv "${ODOO_VENV}"
fi
runuser -u "${ODOO_USER}" -- "${ODOO_VENV}/bin/pip" install --upgrade pip wheel setuptools
runuser -u "${ODOO_USER}" -- "${ODOO_VENV}/bin/pip" install -r "${ODOO_SRC}/requirements.txt"

#--- 8. Odoo configuration -------------------------------------------------------
if [[ -f "${ODOO_CONF}" ]] && grep -q '^admin_passwd' "${ODOO_CONF}"; then
    ADMIN_PASSWD="$(sed -nE 's/^admin_passwd[[:space:]]*=[[:space:]]*//p' "${ODOO_CONF}" | head -1)"
    log "Keeping existing master password."
else
    ADMIN_PASSWD="$(gen_pass 20)"
fi

cat > "${ODOO_CONF}" <<EOF
[options]
admin_passwd = ${ADMIN_PASSWD}
db_host = 127.0.0.1
db_port = ${PG_PORT}
db_user = ${ODOO_USER}
db_password = ${DB_PASSWD}
addons_path = ${ODOO_SRC}/addons,${ODOO_HOME}/custom-addons
logfile = ${ODOO_LOG_DIR}/odoo20.log
data_dir = ${ODOO_HOME}/.local/share/Odoo
proxy_mode = True
http_interface = 127.0.0.1
http_port = ${ODOO_PORT}
gevent_port = ${ODOO_GEVENT_PORT}
workers = ${WORKERS}
max_cron_threads = 1
limit_memory_soft = 2147483648
limit_memory_hard = 2684354560
limit_time_cpu = 600
limit_time_real = 1200
EOF
chown "${ODOO_USER}:${ODOO_USER}" "${ODOO_CONF}"
chmod 640 "${ODOO_CONF}"

cat > "/etc/systemd/system/${ODOO_SERVICE}.service" <<EOF
[Unit]
Description=Odoo 20
After=network.target postgresql.service
Wants=postgresql.service

[Service]
Type=simple
User=${ODOO_USER}
Group=${ODOO_USER}
ExecStart=${ODOO_VENV}/bin/python ${ODOO_SRC}/odoo-bin -c ${ODOO_CONF}
Restart=on-failure
RestartSec=5
KillMode=mixed

[Install]
WantedBy=multi-user.target
EOF

#--- 9. Nginx + SSL ---------------------------------------------------------------
log "Installing Nginx (HTTPS on port ${NGINX_PORT})..."
apt-get install -y nginx

SSL_DIR="/etc/ssl/odoo20"
SSL_CERT="${SSL_DIR}/odoo20.crt"
SSL_KEY="${SSL_DIR}/odoo20.key"
SSL_TYPE="self-signed"
DOMAIN_RE='^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$'

if [[ "${SERVER_NAME}" =~ ${DOMAIN_RE} ]]; then
    log "Domain ${SERVER_NAME} detected - requesting Let's Encrypt certificate..."
    apt-get install -y certbot
    LE_ARGS=(--non-interactive --agree-tos)
    if [[ -n "${LE_EMAIL}" ]]; then LE_ARGS+=(--email "${LE_EMAIL}"); else LE_ARGS+=(--register-unsafely-without-email); fi
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then ufw allow 80/tcp; fi
    systemctl stop nginx 2>/dev/null || true
    if certbot certonly --standalone --preferred-challenges http \
            -d "${SERVER_NAME}" "${LE_ARGS[@]}" \
            --pre-hook "systemctl stop nginx" --post-hook "systemctl start nginx"; then
        SSL_CERT="/etc/letsencrypt/live/${SERVER_NAME}/fullchain.pem"
        SSL_KEY="/etc/letsencrypt/live/${SERVER_NAME}/privkey.pem"
        SSL_TYPE="letsencrypt"
        log "Let's Encrypt certificate issued (auto-renews)."
    else
        warn "Let's Encrypt failed (check DNS and that port 80 is open) - using self-signed."
    fi
fi

if [[ "${SSL_TYPE}" == "self-signed" ]]; then
    log "Generating self-signed certificate..."
    mkdir -p "${SSL_DIR}"
    SAN="DNS:localhost,IP:127.0.0.1"
    CN="$(hostname -I | awk '{print $1}')"
    CN="${CN:-localhost}"
    if [[ "${SERVER_NAME}" =~ ${DOMAIN_RE} ]]; then
        SAN="DNS:${SERVER_NAME},${SAN}"; CN="${SERVER_NAME}"
    fi
    for ip in $(hostname -I) $(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || true); do
        if [[ "${ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && "${SAN}" != *"IP:${ip}"* ]]; then
            SAN="${SAN},IP:${ip}"
        fi
    done
    openssl req -x509 -nodes -newkey rsa:2048 -sha256 -days 825 \
        -keyout "${SSL_KEY}" -out "${SSL_CERT}" \
        -subj "/C=US/O=Odoo20/CN=${CN}" -addext "subjectAltName=${SAN}"
    chmod 600 "${SSL_KEY}"
    warn "Self-signed certificate: browsers will show a warning until you accept it."
fi

# Only listen on IPv6 if the kernel has it enabled (otherwise nginx fails to start)
LISTEN_V6=""
if [[ -f /proc/net/if_inet6 && "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 0)" != "1" ]]; then
    LISTEN_V6="listen [::]:${NGINX_PORT} ssl;"
fi

# When serving on 443, also answer plain http:// on port 80 with a redirect
HTTP_REDIRECT_BLOCK=""
PORT80_BUSY=0
if ss -ltnpH "sport = :80" 2>/dev/null | grep -v nginx | grep -q .; then PORT80_BUSY=1; fi
if [[ "${NGINX_PORT}" == "443" && ${PORT80_BUSY} -eq 1 ]]; then
    warn "Port 80 is used by another service (e.g. apache2) - skipping the http->https redirect."
    warn "Use https://<ip> directly. To enable the redirect later: stop that service and rerun this script."
fi
if [[ "${NGINX_PORT}" == "443" && ${PORT80_BUSY} -eq 0 ]]; then
    HTTP_REDIRECT_BLOCK='server {
    listen 80;
    listen [::]:80;
    server_name '"${SERVER_NAME}"';
    return 301 https://$host$request_uri;
}'
    [[ -n "${LISTEN_V6}" ]] || HTTP_REDIRECT_BLOCK="${HTTP_REDIRECT_BLOCK/listen \[::\]:80;/}"
fi

cat > "/etc/nginx/sites-available/${NGINX_SITE}" <<EOF
# Odoo 20 reverse proxy - HTTPS on ${NGINX_PORT}
upstream odoo20_backend   { server 127.0.0.1:${ODOO_PORT}; }
upstream odoo20_websocket { server 127.0.0.1:${ODOO_GEVENT_PORT}; }

map \$http_upgrade \$odoo20_connection_upgrade {
    default upgrade;
    ''      close;
}

${HTTP_REDIRECT_BLOCK}

server {
    listen ${NGINX_PORT} ssl;
    ${LISTEN_V6}
    server_name ${SERVER_NAME};

    ssl_certificate     ${SSL_CERT};
    ssl_certificate_key ${SSL_KEY};
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_session_cache   shared:odoo20_ssl:10m;
    ssl_session_timeout 10m;

    # plain http:// sent to the https port -> redirect
    error_page 497 =301 https://\$host:\$server_port\$request_uri;

    access_log /var/log/nginx/odoo20.access.log;
    error_log  /var/log/nginx/odoo20.error.log;

    client_max_body_size 200m;
    proxy_read_timeout    720s;
    proxy_connect_timeout 720s;
    proxy_send_timeout    720s;

    proxy_set_header Host              \$http_host;
    proxy_set_header X-Real-IP         \$remote_addr;
    proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Forwarded-Host  \$host;

    location /websocket {
        proxy_pass http://odoo20_websocket;
        proxy_http_version 1.1;
        proxy_set_header Upgrade    \$http_upgrade;
        proxy_set_header Connection \$odoo20_connection_upgrade;
        proxy_set_header Host       \$http_host;
        proxy_set_header X-Real-IP  \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 3600s;
    }

    location / {
        proxy_pass http://odoo20_backend;
        proxy_redirect off;
    }

    location ~* /web/static/ {
        proxy_buffering on;
        expires 10d;
        proxy_pass http://odoo20_backend;
    }

    gzip on;
    gzip_min_length 1100;
    gzip_buffers 4 32k;
    gzip_types text/css text/plain text/xml application/xml application/json
               application/javascript image/jpeg image/png;
    gzip_vary on;
}
EOF

ln -sf "/etc/nginx/sites-available/${NGINX_SITE}" "/etc/nginx/sites-enabled/${NGINX_SITE}"
rm -f /etc/nginx/sites-enabled/default      # avoids clashes on port 80
nginx -t || die "Nginx configuration test failed."

# Is something other than nginx already using our port?
CHECK_PORTS=("${NGINX_PORT}")
for _p in "${CHECK_PORTS[@]}"; do
    if ss -ltnpH "sport = :${_p}" 2>/dev/null | grep -v nginx | grep -q .; then
        warn "Port ${_p} is already in use by:"
        ss -ltnp "sport = :${_p}" || true
        die "Stop that service (e.g. 'sudo systemctl disable --now apache2') or use another port: NGINX_PORT=8443 sudo -E bash $0"
    fi
done

systemctl enable nginx >/dev/null 2>&1
if ! systemctl restart nginx; then
    warn "Nginx failed to start. Listening sockets on 80/${NGINX_PORT}:"
    ss -ltnp 2>/dev/null | grep -E ":(80|${NGINX_PORT})\\b" || true
    echo "------------------------------------------------------------"
    journalctl -u nginx -n 25 --no-pager || true
    tail -n 15 /var/log/nginx/error.log 2>/dev/null || true
    echo "------------------------------------------------------------"
    die "Nginx did not start - see the output above."
fi

if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    log "UFW active - opening ${NGINX_PORT}/tcp..."
    ufw allow "${NGINX_PORT}/tcp"
    if [[ "${NGINX_PORT}" == "443" && ${PORT80_BUSY} -eq 0 ]]; then ufw allow 80/tcp; fi
fi

#--- 9b. Create and initialise the database -------------------------------------
# An existing, initialised database is left alone; an empty/half-built one is recreated.
DB_NAME="${DB_NAME-odoo}"
DEMO="${DEMO:-0}"
DB_STATUS="skipped"
WEB_PASSWD="(unchanged)"
if [[ -n "${DB_NAME}" ]]; then
    [[ "${DB_NAME}" =~ ^[A-Za-z0-9_]+$ ]] || die "DB_NAME may only contain letters, digits and _"
    cd /
    systemctl stop "${ODOO_SERVICE}" 2>/dev/null || true
    DB_EXISTS="$(runuser -u "${ODOO_USER}" -- psql -p "${PG_PORT}" -d postgres -tAc \
        "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" 2>/dev/null || true)"
    DB_INIT="f"
    if [[ "${DB_EXISTS}" == "1" ]]; then
        DB_INIT="$(runuser -u "${ODOO_USER}" -- psql -p "${PG_PORT}" -d "${DB_NAME}" -tAc \
            "SELECT to_regclass('public.ir_module_module') IS NOT NULL" 2>/dev/null || echo f)"
    fi
    if [[ "${DB_INIT}" == "t" ]]; then
        log "Database ${DB_NAME} already initialised - keeping it."
        DB_STATUS="existing"
    else
        log "Creating database ${DB_NAME} and installing base modules (a few minutes)..."
        runuser -u "${ODOO_USER}" -- dropdb -p "${PG_PORT}" --if-exists "${DB_NAME}"
        runuser -u "${ODOO_USER}" -- createdb -p "${PG_PORT}" -E UTF8 -T template0 "${DB_NAME}"
        DEMO_FLAG="--without-demo=all"; [[ "${DEMO}" == "1" ]] && DEMO_FLAG=""
        runuser -u "${ODOO_USER}" -- "${ODOO_VENV}/bin/python" "${ODOO_SRC}/odoo-bin" \
            -c "${ODOO_CONF}" -d "${DB_NAME}" -i base ${DEMO_FLAG} --stop-after-init \
            --logfile= --log-level=info \
            || {
                warn "Database initialisation failed. Last lines of the Odoo log:"
                echo "------------------------------------------------------------"
                tail -n 50 "${ODOO_LOG_DIR}/odoo20.log" 2>/dev/null || true
                echo "------------------------------------------------------------"
                die "Initialisation failed - paste the error above (the last ERROR/CRITICAL lines)."
            }
        DB_STATUS="created"
        WEB_PASSWD="$(gen_pass 16)"
        SHELL_OUT="$(cat <<'PYEOF' | ODOO_WEB_PW="${WEB_PASSWD}" runuser -u "${ODOO_USER}" -- env ODOO_WEB_PW="${WEB_PASSWD}" \
            "${ODOO_VENV}/bin/python" "${ODOO_SRC}/odoo-bin" shell -c "${ODOO_CONF}" -d "${DB_NAME}" --logfile= 2>&1 || true
import os
pw = os.environ['ODOO_WEB_PW']
u = env.ref('base.user_admin')
u.write({'password': pw})
env.cr.commit()
try:
    u._check_credentials({'type': 'password', 'password': pw}, {'interactive': False})
    print('WEBPW_OK')
except Exception as e:
    u.write({'password': 'admin'})
    env.cr.commit()
    print('WEBPW_FAIL', e)
PYEOF
)"
        if grep -q "WEBPW_OK" <<<"${SHELL_OUT}"; then
            log "Random password set for web user 'admin'."
        else
            WEB_PASSWD="admin"
            warn "Could not set a random web password - login is admin / admin, CHANGE IT after first login."
        fi
    fi
fi

#--- 10. Start and test -------------------------------------------------------------
log "Starting Odoo..."
systemctl daemon-reload
systemctl enable "${ODOO_SERVICE}" >/dev/null 2>&1
systemctl restart "${ODOO_SERVICE}"

log "Waiting for Odoo on port ${ODOO_PORT} (up to 2 minutes)..."
ok=0
for _ in $(seq 1 40); do
    if curl -s -o /dev/null "http://127.0.0.1:${ODOO_PORT}/web/login"; then ok=1; break; fi
    sleep 3
done
if [[ ${ok} -ne 1 ]]; then
    warn "Odoo is not answering. Last log lines:"
    journalctl -u "${ODOO_SERVICE}" -n 40 --no-pager || true
    tail -n 40 "${ODOO_LOG_DIR}/odoo20.log" 2>/dev/null || true
    die "Odoo failed to start - see the output above."
fi

ODOO_CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${ODOO_PORT}/web/login")"
NGINX_CODE="$(curl -k -s -o /dev/null -w '%{http_code}' "https://127.0.0.1:${NGINX_PORT}/web/login" || true)"
IP="$(hostname -I | awk '{print $1}')"
HOST_SHOWN="${IP}"; [[ "${SERVER_NAME}" =~ ${DOMAIN_RE} ]] && HOST_SHOWN="${SERVER_NAME}"
URL_PORT=""
if [[ "${NGINX_PORT}" != "443" ]]; then URL_PORT=":${NGINX_PORT}"; fi
ODOO_URL="https://${HOST_SHOWN}${URL_PORT}"

umask 077
cat > "${CRED_FILE}" <<EOF
Odoo URL        : ${ODOO_URL}
Master password : ${ADMIN_PASSWD}
Database        : ${DB_NAME:-none} (${DB_STATUS})
Web login       : admin / ${WEB_PASSWD}
PostgreSQL role : ${ODOO_USER} / ${DB_PASSWD}  (127.0.0.1:${PG_PORT})
Config file     : ${ODOO_CONF}
Log file        : ${ODOO_LOG_DIR}/odoo20.log
EOF

echo
echo "=============================================================="
echo "  Python : ${PYV}"
echo "  Odoo   (:${ODOO_PORT}) -> HTTP ${ODOO_CODE}"
echo "  Nginx  (:${NGINX_PORT}) -> HTTP ${NGINX_CODE}"
echo "  SSL    : ${SSL_TYPE}"
echo "  Open   : ${ODOO_URL}"
echo "  DB     : ${DB_NAME:-none} - ${DB_STATUS}"
echo "  Login  : admin / ${WEB_PASSWD}"
echo "  Master password saved in ${CRED_FILE}"
echo "=============================================================="
