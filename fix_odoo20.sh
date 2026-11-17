#!/usr/bin/env bash
#=============================================================================
# fix_odoo20.sh - repair an Odoo 20 install that fails with:
#   "Outdated python version detected, Odoo requires Python >= 3.12"
# Rebuilds the venv with Python 3.12, reinstalls requirements, (re)creates the
# Nginx reverse proxy on port 8020, restarts everything and tests it.
#
# Usage: sudo bash fix_odoo20.sh
# Options: NGINX_PORT=8020  SERVER_NAME=_  (or your domain)  LE_EMAIL=you@example.com
#=============================================================================
set -Eeuo pipefail

ODOO_USER="odoo20"
ODOO_HOME="/opt/odoo20"
ODOO_SERVICE="odoo20"
ODOO_PORT="8069"
ODOO_GEVENT_PORT="8072"
ODOO_CONF="/etc/odoo20.conf"
NGINX_PORT="${NGINX_PORT:-8020}"
SERVER_NAME="${SERVER_NAME:-_}"
LE_EMAIL="${LE_EMAIL:-}"
NGINX_SITE="odoo20"

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

# --- 5. Odoo config for reverse proxy ----------------------------------------
if [[ -f "${ODOO_CONF}" ]]; then
    log "Checking ${ODOO_CONF} for proxy settings..."
    set_opt() {  # set_opt key value
        if grep -qE "^[[:space:]]*$1[[:space:]]*=" "${ODOO_CONF}"; then
            sed -i -E "s|^[[:space:]]*$1[[:space:]]*=.*|$1 = $2|" "${ODOO_CONF}"
        else
            echo "$1 = $2" >> "${ODOO_CONF}"
        fi
    }
    set_opt proxy_mode True
    set_opt http_interface 127.0.0.1
    set_opt http_port "${ODOO_PORT}"
    set_opt gevent_port "${ODOO_GEVENT_PORT}"
else
    warn "${ODOO_CONF} not found - run odoo20_community.sh first."
fi

# --- 6. Nginx reverse proxy ---------------------------------------------------
log "Installing and configuring Nginx (port ${NGINX_PORT})..."
apt-get install -y nginx

# ----------------------------- SSL certificate ------------------------------
# Real domain  -> try Let's Encrypt (needs DNS pointing here + port 80 open)
# Anything else (or LE fails) -> self-signed certificate
SSL_DIR="/etc/ssl/odoo20"
SSL_CERT="${SSL_DIR}/odoo20.crt"
SSL_KEY="${SSL_DIR}/odoo20.key"
SSL_TYPE="self-signed"
LE_EMAIL="${LE_EMAIL:-}"
DOMAIN_RE='^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$'

if [[ "${SERVER_NAME}" =~ ${DOMAIN_RE} ]]; then
    log "Domain ${SERVER_NAME} detected - requesting Let's Encrypt certificate..."
    apt-get install -y certbot
    LE_ARGS=(--non-interactive --agree-tos)
    if [[ -n "${LE_EMAIL}" ]]; then
        LE_ARGS+=(--email "${LE_EMAIL}")
    else
        LE_ARGS+=(--register-unsafely-without-email)
    fi
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        ufw allow 80/tcp
    fi
    systemctl stop nginx 2>/dev/null || true   # certbot standalone needs port 80
    if certbot certonly --standalone --preferred-challenges http \
            -d "${SERVER_NAME}" "${LE_ARGS[@]}" \
            --pre-hook "systemctl stop nginx" --post-hook "systemctl start nginx"; then
        SSL_CERT="/etc/letsencrypt/live/${SERVER_NAME}/fullchain.pem"
        SSL_KEY="/etc/letsencrypt/live/${SERVER_NAME}/privkey.pem"
        SSL_TYPE="letsencrypt"
        log "Let's Encrypt certificate issued (auto-renews via certbot timer)."
    else
        warn "Let's Encrypt failed (check DNS for ${SERVER_NAME} and that port 80 is open)."
        warn "Falling back to a self-signed certificate."
    fi
fi

if [[ "${SSL_TYPE}" == "self-signed" ]]; then
    log "Generating self-signed certificate..."
    mkdir -p "${SSL_DIR}"
    SSL_CERT="${SSL_DIR}/odoo20.crt"
    SSL_KEY="${SSL_DIR}/odoo20.key"

    SAN="DNS:localhost,IP:127.0.0.1"
    CN="$(hostname -I | awk '{print $1}')"
    if [[ "${SERVER_NAME}" =~ ${DOMAIN_RE} ]]; then
        SAN="DNS:${SERVER_NAME},${SAN}"
        CN="${SERVER_NAME}"
    fi
    for ip in $(hostname -I) $(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || true); do
        [[ "${ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ "${SAN}" != *"IP:${ip}"* ]] && SAN="${SAN},IP:${ip}"
    done

    openssl req -x509 -nodes -newkey rsa:2048 -sha256 -days 825 \
        -keyout "${SSL_KEY}" -out "${SSL_CERT}" \
        -subj "/C=US/O=Odoo20/CN=${CN}" \
        -addext "subjectAltName=${SAN}"
    chmod 600 "${SSL_KEY}"
    warn "Self-signed certificate: browsers will show a warning until you accept it."
fi


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
    listen ${NGINX_PORT} ssl;
    listen [::]:${NGINX_PORT} ssl;
    server_name ${SERVER_NAME};

    ssl_certificate     ${SSL_CERT};
    ssl_certificate_key ${SSL_KEY};
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_session_cache   shared:odoo20_ssl:10m;
    ssl_session_timeout 10m;

    # Plain http:// request sent to the https port -> redirect to https
    error_page 497 =301 https://\$host:\$server_port\$request_uri;

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

    gzip on;
    gzip_min_length 1100;
    gzip_buffers 4 32k;
    gzip_types text/css text/less text/plain text/xml application/xml
               application/json application/javascript application/pdf image/jpeg image/png;
    gzip_vary on;
}
EOF

ln -sf "/etc/nginx/sites-available/${NGINX_SITE}" "/etc/nginx/sites-enabled/${NGINX_SITE}"
nginx -t || die "Nginx configuration test failed (see above)."
systemctl enable nginx >/dev/null 2>&1
systemctl restart nginx

if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    log "UFW active - opening ${NGINX_PORT}/tcp..."
    ufw allow "${NGINX_PORT}/tcp"
fi

# --- 7. Restart and test -----------------------------------------------------
log "Starting Odoo..."
systemctl daemon-reload
systemctl enable "${ODOO_SERVICE}" >/dev/null 2>&1
systemctl restart "${ODOO_SERVICE}"

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
NGINX_CODE="$(curl -k -s -o /dev/null -w '%{http_code}' "https://127.0.0.1:${NGINX_PORT}/web/login" || true)"
IP="$(hostname -I | awk '{print $1}')"

echo
echo "=============================================================="
echo "  Odoo  (:${ODOO_PORT}) -> HTTP ${ODOO_CODE}"
echo "  Nginx (:${NGINX_PORT}) -> HTTP ${NGINX_CODE}"
echo "  SSL   : ${SSL_TYPE}"
echo "  Open  : https://${IP}:${NGINX_PORT}"
echo "=============================================================="
