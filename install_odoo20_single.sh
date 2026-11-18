#!/usr/bin/env bash
#=============================================================================
# install_odoo20_single.sh - Odoo 20 in Docker: ONE instance
#
#  * Installs Docker + Compose if missing
#  * One stack: Odoo 20 + PostgreSQL 16 + Nginx (plain HTTP reverse proxy)
#  * Random passwords, saved to <BASE_DIR>/credentials.txt
#  * Safe to re-run: keeps passwords, config and an already-initialised database
#
# Usage:  sudo bash install_odoo20_single.sh
# Options (env vars):
#   PORT=80                   public HTTP port (if busy and not set, moves to 8080+)
#   DB_NAME=odoo              database to create (DB_NAME= to skip creating one)
#   WORKERS=2                 Odoo workers (0 = threaded mode)
#   DEMO=1                    demo data in a newly created database
#   PYTHON_VERSION=3.12|3.13|3.14   ODOO_BRANCH=20.0 (or master)   PG_VERSION=16
#   PIP_PACKAGES="openpyxl zeep"    extra pip packages (also editable in
#                             <BASE_DIR>/requirements.txt; rerun to apply)
#   RECONFIGURE=1             regenerate odoo.conf (old one saved as odoo.conf.bak)
#   REBUILD=1                 rebuild the image from scratch (pulls newest Odoo code)
#   BASE_DIR=/opt/odoo20-docker
#=============================================================================
set -Eeuo pipefail
trap 'echo -e "\033[0;31m[x]\033[0m Failed at line $LINENO" >&2' ERR

BASE_DIR="${BASE_DIR:-/opt/odoo20-docker}"
PYTHON_VERSION="${PYTHON_VERSION:-3.12}"
ODOO_BRANCH="${ODOO_BRANCH:-20.0}"
PG_VERSION="${PG_VERSION:-16}"
DEMO="${DEMO:-0}"
REBUILD="${REBUILD:-0}"
RECONFIGURE="${RECONFIGURE:-0}"
WORKERS="${WORKERS:-2}"
PORT_SET="${PORT+x}"; PORT="${PORT:-80}"
DB_NAME="${DB_NAME-odoo}"
PIP_PACKAGES="${PIP_PACKAGES:-}"
CONF_FILE="odoo.conf"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*" >&2; }
die()  { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }
gen_pass() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-"${1:-24}"; }
port_busy() { ss -ltnpH "sport = :$1" 2>/dev/null | grep -vE 'docker-proxy|nginx' | grep -q .; }

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0"
[[ "${PYTHON_VERSION}" =~ ^3\.(12|13|14)$ ]] || die "PYTHON_VERSION must be 3.12, 3.13 or 3.14."
[[ -z "${DB_NAME}" || "${DB_NAME}" =~ ^[A-Za-z0-9_]+$ ]] || die "DB_NAME may only contain letters, digits and _"
[[ "${WORKERS}" =~ ^[0-9]+$ ]] || die "WORKERS must be a number"
[[ "${PORT}" =~ ^[0-9]+$ ]] || die "PORT must be a number"
export DEBIAN_FRONTEND=noninteractive

#--- 1. Docker ---------------------------------------------------------------
if ! command -v docker &>/dev/null; then
    log "Installing Docker..."
    apt-get update -y
    apt-get install -y curl ca-certificates openssl iproute2
    curl -fsSL https://get.docker.com | sh
fi
command -v openssl &>/dev/null || apt-get install -y openssl
command -v ss &>/dev/null      || apt-get install -y iproute2
command -v curl &>/dev/null    || apt-get install -y curl
systemctl enable --now docker
if ! docker compose version &>/dev/null; then
    log "Installing Docker Compose plugin..."
    apt-get install -y docker-compose-plugin || apt-get install -y docker-compose-v2 \
        || die "Could not install the Docker Compose plugin."
fi
DC="docker compose"

#--- 2. Port -----------------------------------------------------------------
if port_busy "${PORT}"; then
    warn "Port ${PORT} is already in use:"
    ss -ltnp "sport = :${PORT}" >&2 || true
    [[ -z "${PORT_SET}" ]] || die "Free port ${PORT} (e.g. 'sudo systemctl disable --now apache2') or choose another PORT."
    p=8080
    while port_busy "${p}"; do p=$((p+1)); done
    warn "Using port ${p} instead."
    PORT="${p}"
fi

#--- 3. Project files --------------------------------------------------------
mkdir -p "${BASE_DIR}/addons" "${BASE_DIR}/custom-addons"
chmod 700 "${BASE_DIR}"
cd "${BASE_DIR}"

# keep passwords on reruns (the PostgreSQL volume remembers the old one)
PGPASS=""; ADMINPW=""
if [[ -f .env ]]; then
    PGPASS="$(sed -nE 's/^POSTGRES_PASSWORD=//p' .env | head -1)"
    ADMINPW="$(sed -nE 's/^ADMIN_PASSWD=//p' .env | head -1)"
fi
PGPASS="${PGPASS:-$(gen_pass 24)}"; ADMINPW="${ADMINPW:-$(gen_pass 20)}"

cat > .env <<EOF
COMPOSE_PROJECT_NAME=odoo20
ODOO_CONF_FILE=${CONF_FILE}
HTTP_PORT=${PORT}
PG_VERSION=${PG_VERSION}
PYTHON_VERSION=${PYTHON_VERSION}
ODOO_BRANCH=${ODOO_BRANCH}
POSTGRES_PASSWORD=${PGPASS}
ADMIN_PASSWD=${ADMINPW}
EOF
chmod 600 .env

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

# custom pip packages (a separate layer, so editing requirements.txt is quick)
COPY requirements.txt /tmp/requirements-custom.txt
RUN pip install -r /tmp/requirements-custom.txt

USER odoo
EXPOSE 8069 8072
ENTRYPOINT ["python", "/opt/odoo/odoo-bin"]
CMD ["-c", "/etc/odoo/odoo.conf"]
DOCKERFILE
printf '*\n!requirements.txt\n!Dockerfile\n' > .dockerignore

if [[ ! -f requirements.txt ]]; then
    cat > requirements.txt <<'REQ'
# Custom Python packages (one per line, pip syntax).
# Rerun install_odoo20_single.sh (or "docker compose build odoo && docker compose up -d")
# to install them. Examples:
#   openpyxl
#   zeep>=4.2
REQ
fi
read -ra _pk <<<"${PIP_PACKAGES}"
for _p in "${_pk[@]}"; do
    grep -qxF "${_p}" requirements.txt || echo "${_p}" >> requirements.txt
done

cat > docker-compose.yml <<'COMPOSE'
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
    command: ["-c", "/etc/odoo/${ODOO_CONF_FILE}"]
    depends_on:
      db:
        condition: service_healthy
    volumes:
      - odoo-data:/var/lib/odoo
      - ./${ODOO_CONF_FILE}:/etc/odoo/${ODOO_CONF_FILE}:ro
      - ./addons:/mnt/extra-addons
      - ./custom-addons:/mnt/custom-addons

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

if [[ ! -f docker-compose.override.yml ]]; then
    cat > docker-compose.override.yml <<'OVR'
# Extra settings merged automatically into docker-compose.yml (never overwritten).
# Example: mount more addon folders, then list them in addons_path of odoo.conf:
#
# services:
#   odoo:
#     volumes:
#       - /srv/git/oca-web:/mnt/custom-addons/oca-web
#     environment:
#       TZ: Asia/Kolkata
OVR
fi

#--- 4. Odoo config (created once; your edits are kept) ----------------------
if [[ -f "${CONF_FILE}" && "${RECONFIGURE}" == "1" ]]; then
    cp -a "${CONF_FILE}" "${CONF_FILE}.bak"
    rm -f "${CONF_FILE}"
    log "Old config saved as ${CONF_FILE}.bak"
fi
if [[ ! -f "${CONF_FILE}" ]]; then
    log "Writing ${CONF_FILE}"
    {
cat <<EOF
[options]
; ---- edit freely, then: docker compose restart odoo ----
admin_passwd = ${ADMINPW}

; ---- database ----
db_host = db
db_port = 5432
db_user = odoo
db_password = ${PGPASS}

; ---- addons (paths as seen INSIDE the container) ----
;   /opt/odoo/addons     standard Odoo addons
;   /mnt/extra-addons    ./addons          (host folder)
;   /mnt/custom-addons   ./custom-addons   (host folder, e.g. git clones)
addons_path = /opt/odoo/addons,/mnt/extra-addons,/mnt/custom-addons
data_dir = /var/lib/odoo

; ---- proxy / workers ----
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
    } > "${CONF_FILE}"
else
    log "Keeping existing ${CONF_FILE} (RECONFIGURE=1 to regenerate)"
fi
chmod 644 "${CONF_FILE}"   # parent directory is root-only (700)

#--- 5. Build image ----------------------------------------------------------
log "Building image (Python ${PYTHON_VERSION}, Odoo ${ODOO_BRANCH}) - first build takes several minutes..."
BUILD_OPTS=()
[[ "${REBUILD}" == "1" ]] && BUILD_OPTS+=(--no-cache --pull)
$DC build "${BUILD_OPTS[@]}" odoo \
    || die "Image build failed. If the git clone failed, retry with ODOO_BRANCH=master. Check requirements.txt for pip errors."

#--- 6. Database -------------------------------------------------------------
log "Starting PostgreSQL ${PG_VERSION}..."
$DC stop odoo nginx >/dev/null 2>&1 || true
$DC up -d --wait db

DB_STATUS="skipped"; WEB_PASSWD="(unchanged)"
if [[ -n "${DB_NAME}" ]]; then
    INIT="f"; DEMO_FLAG="--without-demo=all"
    EXISTS="$($DC exec -T db psql -U odoo -d postgres -tAc \
        "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "${EXISTS}" == "1" ]]; then
        INIT="$($DC exec -T db psql -U odoo -d "${DB_NAME}" -tAc \
            "SELECT to_regclass('public.ir_module_module') IS NOT NULL" 2>/dev/null | tr -d '[:space:]' || echo f)"
    fi
    if [[ "${INIT}" == "t" ]]; then
        log "Database ${DB_NAME} already initialised - keeping it."
        DB_STATUS="existing"
    else
        log "Creating database ${DB_NAME} and installing base modules (a few minutes)..."
        $DC exec -T db dropdb -U odoo --if-exists "${DB_NAME}"
        $DC exec -T db createdb -U odoo -E UTF8 -T template0 "${DB_NAME}"
        [[ "${DEMO}" == "1" ]] && DEMO_FLAG=""
        $DC run --rm -T odoo -c "/etc/odoo/${CONF_FILE}" -d "${DB_NAME}" -i base ${DEMO_FLAG} \
            --stop-after-init --workers=0 2>&1 | tee /tmp/odoo20_init.log \
            || {
                warn "Database initialisation failed. First errors in the output:"
                awk '/ (ERROR|CRITICAL) /{f=1} f{print; if(++n>=45) exit}' /tmp/odoo20_init.log >&2
                die "Initialisation failed. Full output: /tmp/odoo20_init.log"
            }
        DB_STATUS="created"

        WEB_PASSWD="$(gen_pass 16)"
        SHELL_OUT="$(cat <<'PYEOF' | $DC run --rm -T -e ODOO_WEB_PW="${WEB_PASSWD}" odoo shell -c "/etc/odoo/${CONF_FILE}" -d "${DB_NAME}" --workers=0 2>&1 || true
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

#--- 7. Start & test ---------------------------------------------------------
log "Starting Odoo and Nginx..."
$DC up -d
$DC restart nginx >/dev/null      # make sure Nginx sees the current Odoo container
if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    ufw allow "${PORT}/tcp" >/dev/null
fi

ok=0
log "Waiting for Odoo on port ${PORT} (up to 3 minutes)..."
for _ in $(seq 1 60); do
    # -f: HTTP errors such as 502 count as "not ready"
    if curl -sf -o /dev/null "http://127.0.0.1:${PORT}/web/login"; then ok=1; break; fi
    sleep 3
done
if [[ ${ok} -ne 1 ]]; then
    warn "Odoo is not answering. Container status and last log lines:"
    $DC ps || true
    $DC logs --tail 60 odoo nginx || true
    die "Odoo did not come up - see the output above."
fi

URL_PORT=""; [[ "${PORT}" != "80" ]] && URL_PORT=":${PORT}"
IP="$(hostname -I | awk '{print $1}')"
URL="http://${IP}${URL_PORT}"

umask 077
cat > "${BASE_DIR}/credentials.txt" <<EOF
Odoo URL        : ${URL}
Master password : ${ADMINPW}
Database        : ${DB_NAME:-none} (${DB_STATUS})
Web login       : admin / ${WEB_PASSWD}
PostgreSQL role : odoo / ${PGPASS}   (inside Docker only)
Project dir     : ${BASE_DIR}
Config file     : ${BASE_DIR}/${CONF_FILE}
Custom pip      : ${BASE_DIR}/requirements.txt
EOF

echo
echo "=============================================================="
echo "  Odoo URL  : ${URL}"
echo "  Database  : ${DB_NAME:-none} (${DB_STATUS})"
echo "  Login     : admin / ${WEB_PASSWD}"
echo "--------------------------------------------------------------"
echo "  Secrets   : ${BASE_DIR}/credentials.txt"
echo "  Logs      : cd ${BASE_DIR} && docker compose logs -f odoo"
echo "  Restart   : cd ${BASE_DIR} && docker compose restart odoo"
echo "  Stop      : cd ${BASE_DIR} && docker compose down"
echo "  Config    : ${BASE_DIR}/${CONF_FILE}"
echo "  Addons    : ${BASE_DIR}/addons and ${BASE_DIR}/custom-addons"
echo "  Custom pip: ${BASE_DIR}/requirements.txt, then rerun this script"
echo "=============================================================="
