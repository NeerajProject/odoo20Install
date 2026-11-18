#!/usr/bin/env bash
#=============================================================================
# install_odoo20_docker.sh - Odoo 20 in Docker (image built locally)
#
#  * Installs Docker + Compose if missing
#  * Builds an Odoo 20 image on python:3.12 (3.12 - 3.14 supported)
#  * Runs PostgreSQL 16 + Odoo + Nginx reverse proxy (plain HTTP, no SSL)
#  * Random DB password, master password and web admin password
#
# Usage:  sudo bash install_odoo20_docker.sh
# Options (env vars):
#   PROJECT_DIR=/opt/odoo20-docker   HTTP_PORT=80 (falls back to 8020 if busy)
#   PYTHON_VERSION=3.12|3.13|3.14    ODOO_BRANCH=20.0 (or master)
#   PG_VERSION=16   WORKERS=2   DB_NAME=odoo (DB_NAME= to skip)   DEMO=1
#   REBUILD=1  rebuild the image from scratch (pulls the newest Odoo code)
#=============================================================================
set -Eeuo pipefail
trap 'echo -e "\033[0;31m[x]\033[0m Failed at line $LINENO" >&2' ERR

PROJECT_DIR="${PROJECT_DIR:-/opt/odoo20-docker}"
PYTHON_VERSION="${PYTHON_VERSION:-3.12}"
ODOO_BRANCH="${ODOO_BRANCH:-20.0}"
PG_VERSION="${PG_VERSION:-16}"
WORKERS="${WORKERS:-2}"
HTTP_PORT_SET="${HTTP_PORT+x}"
HTTP_PORT="${HTTP_PORT:-80}"
DB_NAME="${DB_NAME-odoo}"
DEMO="${DEMO:-0}"
REBUILD="${REBUILD:-0}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }
gen_pass() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-"${1:-24}"; }
port_busy() { ss -ltnpH "sport = :$1" 2>/dev/null | grep -vE 'docker-proxy|nginx' | grep -q .; }

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0"
[[ "${PYTHON_VERSION}" =~ ^3\.(12|13|14)$ ]] || die "PYTHON_VERSION must be 3.12, 3.13 or 3.14 (Odoo 20 requirement)."
[[ -z "${DB_NAME}" || "${DB_NAME}" =~ ^[A-Za-z0-9_]+$ ]] || die "DB_NAME may only contain letters, digits and _"
. /etc/os-release
export DEBIAN_FRONTEND=noninteractive

#--- 1. Docker ---------------------------------------------------------------
if ! command -v docker &>/dev/null; then
    log "Installing Docker..."
    apt-get update -y
    apt-get install -y curl ca-certificates openssl iproute2
    curl -fsSL https://get.docker.com | sh
fi
command -v openssl &>/dev/null || apt-get install -y openssl
command -v ss &>/dev/null || apt-get install -y iproute2
command -v curl &>/dev/null || apt-get install -y curl
systemctl enable --now docker
if ! docker compose version &>/dev/null; then
    log "Installing Docker Compose plugin..."
    apt-get install -y docker-compose-plugin || apt-get install -y docker-compose-v2 \
        || die "Could not install the Docker Compose plugin."
fi
DC="docker compose"

#--- 2. Port -----------------------------------------------------------------
if port_busy "${HTTP_PORT}"; then
    warn "Port ${HTTP_PORT} is in use by another service:"
    ss -ltnp "sport = :${HTTP_PORT}" || true
    if [[ -z "${HTTP_PORT_SET}" ]] && ! port_busy 8020; then
        warn "Falling back to port 8020 (stop that service and rerun to use port ${HTTP_PORT})."
        HTTP_PORT=8020
    else
        die "Free the port (e.g. 'sudo systemctl disable --now apache2') or choose another: HTTP_PORT=8020 sudo -E bash $0"
    fi
fi

#--- 3. Project files --------------------------------------------------------
mkdir -p "${PROJECT_DIR}/addons"
chmod 700 "${PROJECT_DIR}"
cd "${PROJECT_DIR}"

# Reuse passwords on reruns (the PostgreSQL volume keeps the old DB password)
POSTGRES_PASSWORD=""; ADMIN_PASSWD=""
if [[ -f .env ]]; then
    POSTGRES_PASSWORD="$(sed -nE 's/^POSTGRES_PASSWORD=//p' .env | head -1)"
    ADMIN_PASSWD="$(sed -nE 's/^ADMIN_PASSWD=//p' .env | head -1)"
fi
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(gen_pass 24)}"
ADMIN_PASSWD="${ADMIN_PASSWD:-$(gen_pass 20)}"

cat > .env <<EOF
HTTP_PORT=${HTTP_PORT}
PYTHON_VERSION=${PYTHON_VERSION}
ODOO_BRANCH=${ODOO_BRANCH}
PG_VERSION=${PG_VERSION}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
ADMIN_PASSWD=${ADMIN_PASSWD}
EOF
chmod 600 .env

# ----- Dockerfile -----
cat > Dockerfile <<'DOCKERFILE'
ARG PYTHON_VERSION=3.12
FROM python:${PYTHON_VERSION}-slim-bookworm

ARG ODOO_BRANCH=20.0
ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential git curl ca-certificates fontconfig fonts-dejavu-core \
        libpq-dev libxml2-dev libxslt1-dev libldap2-dev libsasl2-dev libssl-dev \
        libffi-dev libjpeg-dev zlib1g-dev libopenjp2-7-dev libwebp-dev liblcms2-dev \
    && (apt-get install -y --no-install-recommends wkhtmltopdf || true) \
    && (apt-get install -y --no-install-recommends nodejs npm && npm install -g rtlcss || true) \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch ${ODOO_BRANCH} https://github.com/odoo/odoo.git /opt/odoo

RUN pip install --upgrade pip wheel setuptools \
    && pip install -r /opt/odoo/requirements.txt

RUN useradd --system --create-home --home-dir /var/lib/odoo --shell /bin/bash odoo \
    && mkdir -p /mnt/extra-addons /var/lib/odoo \
    && chown -R odoo:odoo /var/lib/odoo /mnt/extra-addons

USER odoo
EXPOSE 8069 8072
ENTRYPOINT ["python", "/opt/odoo/odoo-bin"]
CMD ["-c", "/etc/odoo/odoo.conf"]
DOCKERFILE

# ----- docker-compose.yml -----
cat > docker-compose.yml <<'COMPOSE'
name: odoo20

services:
  db:
    image: postgres:${PG_VERSION}
    restart: unless-stopped
    environment:
      POSTGRES_USER: odoo
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: postgres
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U odoo -d postgres"]
      interval: 5s
      timeout: 5s
      retries: 20

  odoo:
    build:
      context: .
      args:
        PYTHON_VERSION: ${PYTHON_VERSION}
        ODOO_BRANCH: ${ODOO_BRANCH}
    image: odoo20:local
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    volumes:
      - odoo-data:/var/lib/odoo
      - ./odoo.conf:/etc/odoo/odoo.conf:ro
      - ./addons:/mnt/extra-addons

  nginx:
    image: nginx:stable-alpine
    restart: unless-stopped
    depends_on:
      - odoo
    ports:
      - "${HTTP_PORT}:80"
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro

volumes:
  pgdata:
  odoo-data:
COMPOSE

# ----- nginx.conf (reverse proxy, plain HTTP) -----
cat > nginx.conf <<'NGINXCONF'
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

upstream odoo_backend   { server odoo:8069; }
upstream odoo_websocket { server odoo:8072; }

server {
    listen 80;
    server_name _;

    client_max_body_size 200m;
    proxy_read_timeout    720s;
    proxy_connect_timeout 720s;
    proxy_send_timeout    720s;

    proxy_set_header Host              $http_host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Host  $host;

    location /websocket {
        proxy_pass http://odoo_websocket;
        proxy_http_version 1.1;
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host       $http_host;
        proxy_read_timeout 3600s;
    }

    location / {
        proxy_pass http://odoo_backend;
        proxy_redirect off;
    }

    location ~* /web/static/ {
        proxy_buffering on;
        expires 10d;
        proxy_pass http://odoo_backend;
    }

    gzip on;
    gzip_min_length 1100;
    gzip_types text/css text/plain text/xml application/xml application/json
               application/javascript image/jpeg image/png;
    gzip_vary on;
}
NGINXCONF

# ----- odoo.conf -----
{
cat <<EOF
[options]
admin_passwd = ${ADMIN_PASSWD}
db_host = db
db_port = 5432
db_user = odoo
db_password = ${POSTGRES_PASSWORD}
addons_path = /opt/odoo/addons,/mnt/extra-addons
data_dir = /var/lib/odoo
proxy_mode = True
http_interface = 0.0.0.0
http_port = 8069
gevent_port = 8072
workers = ${WORKERS}
max_cron_threads = 1
limit_memory_soft = 2147483648
limit_memory_hard = 2684354560
limit_time_cpu = 600
limit_time_real = 1200
EOF
if [[ -n "${DB_NAME}" ]]; then
    echo "db_name = ${DB_NAME}"
    echo "dbfilter = ^${DB_NAME}\$"
fi
} > odoo.conf
chmod 644 odoo.conf   # the project directory itself is root-only (700)

#--- 4. Build image ----------------------------------------------------------
log "Building the Odoo image (Python ${PYTHON_VERSION}, branch ${ODOO_BRANCH}) - this takes several minutes..."
BUILD_ARGS=()
[[ "${REBUILD}" == "1" ]] && BUILD_ARGS+=(--no-cache --pull)
if ! $DC build "${BUILD_ARGS[@]}" odoo; then
    die "Image build failed. If the git clone failed, check the branch (retry with ODOO_BRANCH=master). Scroll up for the exact error."
fi

#--- 5. Database -------------------------------------------------------------
log "Starting PostgreSQL ${PG_VERSION}..."
$DC stop odoo nginx >/dev/null 2>&1 || true
$DC up -d --wait db

DB_STATUS="skipped"
WEB_PASSWD="(unchanged)"
if [[ -n "${DB_NAME}" ]]; then
    DB_EXISTS="$($DC exec -T db psql -U odoo -d postgres -tAc \
        "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" 2>/dev/null | tr -d '[:space:]' || true)"
    DB_INIT="f"
    if [[ "${DB_EXISTS}" == "1" ]]; then
        DB_INIT="$($DC exec -T db psql -U odoo -d "${DB_NAME}" -tAc \
            "SELECT to_regclass('public.ir_module_module') IS NOT NULL" 2>/dev/null | tr -d '[:space:]' || echo f)"
    fi

    if [[ "${DB_INIT}" == "t" ]]; then
        log "Database ${DB_NAME} already initialised - keeping it."
        DB_STATUS="existing"
    else
        log "Creating database ${DB_NAME} and installing base modules (a few minutes)..."
        $DC exec -T db dropdb -U odoo --if-exists "${DB_NAME}"
        $DC exec -T db createdb -U odoo -E UTF8 -T template0 "${DB_NAME}"
        DEMO_FLAG="--without-demo=all"; [[ "${DEMO}" == "1" ]] && DEMO_FLAG=""
        $DC run --rm -T odoo -c /etc/odoo/odoo.conf -d "${DB_NAME}" -i base ${DEMO_FLAG} \
            --stop-after-init --workers=0 2>&1 | tee /tmp/odoo20_docker_init.log \
            || {
                warn "Database initialisation failed. First errors in the output (the root cause is usually here):"
                echo "------------------------------------------------------------"
                awk '/ (ERROR|CRITICAL) /{f=1} f{print; if(++n>=45) exit}' /tmp/odoo20_docker_init.log
                echo "------------------------------------------------------------"
                die "Initialisation failed - paste the block above. Full output: /tmp/odoo20_docker_init.log"
            }
        DB_STATUS="created"

        WEB_PASSWD="$(gen_pass 16)"
        SHELL_OUT="$(cat <<'PYEOF' | $DC run --rm -T -e ODOO_WEB_PW="${WEB_PASSWD}" odoo shell -c /etc/odoo/odoo.conf -d "${DB_NAME}" --workers=0 2>&1 || true
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

#--- 6. Start everything -----------------------------------------------------
log "Starting Odoo and Nginx..."
$DC up -d

if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    log "UFW active - opening ${HTTP_PORT}/tcp..."
    ufw allow "${HTTP_PORT}/tcp"
fi

log "Waiting for Odoo through the proxy on port ${HTTP_PORT} (up to 2 minutes)..."
ok=0
for _ in $(seq 1 40); do
    if curl -s -o /dev/null "http://127.0.0.1:${HTTP_PORT}/web/login"; then ok=1; break; fi
    sleep 3
done
if [[ ${ok} -ne 1 ]]; then
    warn "Odoo is not answering. Container status and last log lines:"
    $DC ps || true
    $DC logs --tail 40 odoo nginx || true
    die "Odoo did not come up - see the output above."
fi

CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${HTTP_PORT}/web/login" || true)"
IP="$(hostname -I | awk '{print $1}')"
URL_PORT=""; if [[ "${HTTP_PORT}" != "80" ]]; then URL_PORT=":${HTTP_PORT}"; fi
ODOO_URL="http://${IP}${URL_PORT}"

umask 077
cat > "${PROJECT_DIR}/credentials.txt" <<EOF
Odoo URL        : ${ODOO_URL}
Master password : ${ADMIN_PASSWD}
Database        : ${DB_NAME:-none} (${DB_STATUS})
Web login       : admin / ${WEB_PASSWD}
PostgreSQL role : odoo / ${POSTGRES_PASSWORD}   (inside Docker only)
Project dir     : ${PROJECT_DIR}
EOF

echo
echo "=============================================================="
echo "  Odoo via Nginx (:${HTTP_PORT}) -> HTTP ${CODE}"
echo "  Open   : ${ODOO_URL}"
echo "  DB     : ${DB_NAME:-none} - ${DB_STATUS}"
echo "  Login  : admin / ${WEB_PASSWD}"
echo "  Secrets: ${PROJECT_DIR}/credentials.txt"
echo "--------------------------------------------------------------"
echo "  Logs   : cd ${PROJECT_DIR} && docker compose logs -f odoo"
echo "  Restart: cd ${PROJECT_DIR} && docker compose restart odoo"
echo "  Stop   : cd ${PROJECT_DIR} && docker compose down"
echo "  Addons : put custom modules in ${PROJECT_DIR}/addons"
echo "=============================================================="
