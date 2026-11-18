#!/usr/bin/env bash
#=============================================================================
# install_odoo20_docker.sh - Odoo 20 in Docker: PRODUCTION + UAT instances
#
#  * Installs Docker + Compose if missing
#  * Builds ONE Odoo 20 image (python:3.12, 3.12-3.14 supported) used by both
#  * Two fully separate stacks (own PostgreSQL 16, volumes, passwords, Nginx):
#        prod -> http://SERVER-IP         (port 80, DB odoo_prod)
#        uat  -> http://SERVER-IP:8020    (port 8020, DB odoo_uat)
#  * Plain HTTP reverse proxy (no SSL), random passwords for everything
#  * Each instance has its OWN config file and its OWN image layer:
#        prod/odoo_production.conf    uat/odoo_uat.conf     (custom addons paths etc.)
#        prod/requirements.txt        uat/requirements.txt  (custom pip packages)
#        prod/docker-compose.override.yml (extra bind mounts / env, never overwritten)
#  * Writes refresh_uat_from_prod.sh to copy production data into UAT
#
# Usage:  sudo bash install_odoo20_docker.sh
# Options (env vars):
#   INSTANCES="prod uat"      (or just "prod" / "uat")
#   PROD_PORT=80  UAT_PORT=8020   (a busy default port moves to a free one from 8080 up)
#   DB_PROD=odoo_prod  DB_UAT=odoo_uat   (DB_xxx= to skip creating the database)
#   WORKERS_PROD=2  WORKERS_UAT=1   DEMO=1 (demo data in newly created DBs)
#   PYTHON_VERSION=3.12|3.13|3.14   ODOO_BRANCH=20.0 (or master)   PG_VERSION=16
#   PIP_PROD="openpyxl zeep"  PIP_UAT="..."   extra pip packages (also editable in
#                             <instance>/requirements.txt; rerun the script to apply)
#   RECONFIGURE=1             regenerate the .conf files (old ones are saved as .bak)
#   BASE_DIR=/opt/odoo20-docker     REBUILD=1 (rebuild images, pulls newest Odoo code)
#=============================================================================
set -Eeuo pipefail
trap 'echo -e "\033[0;31m[x]\033[0m Failed at line $LINENO" >&2' ERR

BASE_DIR="${BASE_DIR:-/opt/odoo20-docker}"
INSTANCES="${INSTANCES:-prod uat}"
PYTHON_VERSION="${PYTHON_VERSION:-3.12}"
ODOO_BRANCH="${ODOO_BRANCH:-20.0}"
PG_VERSION="${PG_VERSION:-16}"
DEMO="${DEMO:-0}"
REBUILD="${REBUILD:-0}"
IMAGE="odoo20:local"

PROD_PORT_SET="${PROD_PORT+x}"; PROD_PORT="${PROD_PORT:-80}"
UAT_PORT_SET="${UAT_PORT+x}";   UAT_PORT="${UAT_PORT:-8020}"
DB_PROD="${DB_PROD-odoo_prod}"
DB_UAT="${DB_UAT-odoo_uat}"
WORKERS_PROD="${WORKERS_PROD:-2}"
WORKERS_UAT="${WORKERS_UAT:-1}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*" >&2; }
die()  { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }
gen_pass() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-"${1:-24}"; }
port_busy() { ss -ltnpH "sport = :$1" 2>/dev/null | grep -vE 'docker-proxy|nginx' | grep -q .; }

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0"
[[ "${PYTHON_VERSION}" =~ ^3\.(12|13|14)$ ]] || die "PYTHON_VERSION must be 3.12, 3.13 or 3.14 (Odoo 20 requirement)."
for i in ${INSTANCES}; do [[ "$i" == "prod" || "$i" == "uat" ]] || die "INSTANCES may only contain: prod uat"; done
for d in "${DB_PROD}" "${DB_UAT}"; do
    [[ -z "$d" || "$d" =~ ^[A-Za-z0-9_]+$ ]] || die "Database names may only contain letters, digits and _"
done
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

#--- 2. Ports ----------------------------------------------------------------
# resolve_port <name> <wanted> <user-set?> <ports already taken...>
resolve_port() {
    local name="$1" want="$2" set="$3"; shift 3
    local taken=" $* " p
    if port_busy "${want}" || [[ "${taken}" == *" ${want} "* ]]; then
        warn "Port ${want} for ${name} is already in use:"
        ss -ltnp "sport = :${want}" >&2 || true
        if [[ -n "${set}" ]]; then
            die "Free port ${want} (e.g. 'sudo systemctl disable --now apache2') or choose another one."
        fi
        p=8080
        while port_busy "${p}" || [[ "${taken}" == *" ${p} "* ]]; do p=$((p+1)); done
        warn "Using port ${p} for ${name} instead."
        want="${p}"
    fi
    echo "${want}"
}
TAKEN=""
if [[ " ${INSTANCES} " == *" prod "* ]]; then
    PROD_PORT="$(resolve_port prod "${PROD_PORT}" "${PROD_PORT_SET}" ${TAKEN})"; TAKEN="${TAKEN} ${PROD_PORT}"
fi
if [[ " ${INSTANCES} " == *" uat "* ]]; then
    UAT_PORT="$(resolve_port uat "${UAT_PORT}" "${UAT_PORT_SET}" ${TAKEN})"; TAKEN="${TAKEN} ${UAT_PORT}"
fi

#--- 3. Build the shared image -----------------------------------------------
mkdir -p "${BASE_DIR}/image"
chmod 700 "${BASE_DIR}"

cat > "${BASE_DIR}/image/Dockerfile" <<'DOCKERFILE'
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

if [[ "${REBUILD}" == "1" ]] || ! docker image inspect "${IMAGE}" &>/dev/null; then
    log "Building image ${IMAGE} (Python ${PYTHON_VERSION}, branch ${ODOO_BRANCH}) - several minutes..."
    BUILD_ARGS=()
    [[ "${REBUILD}" == "1" ]] && BUILD_ARGS+=(--no-cache --pull)
    docker build "${BUILD_ARGS[@]}" \
        --build-arg PYTHON_VERSION="${PYTHON_VERSION}" --build-arg ODOO_BRANCH="${ODOO_BRANCH}" \
        -t "${IMAGE}" "${BASE_DIR}/image" \
        || die "Image build failed. If the git clone failed, retry with ODOO_BRANCH=master. Scroll up for the exact error."
else
    log "Image ${IMAGE} already exists - reusing it (REBUILD=1 to rebuild)."
fi

#--- 4. Deploy one instance --------------------------------------------------
# deploy_instance <name> <http_port> <db_name> <workers>
deploy_instance() {
    local NAME="$1" PORT="$2" DBN="$3" WRK="$4"
    local DIR="${BASE_DIR}/${NAME}"
    local CONF_FILE="odoo_uat.conf" PIP_EXTRA="${PIP_UAT:-}"
    if [[ "${NAME}" == "prod" ]]; then CONF_FILE="odoo_production.conf"; PIP_EXTRA="${PIP_PROD:-}"; fi
    local PGPASS="" ADMINPW="" DB_STATUS="skipped" WEB_PASSWD="(unchanged)"
    log "=== Deploying ${NAME^^} (port ${PORT}) ==="
    mkdir -p "${DIR}/addons" "${DIR}/custom-addons"; cd "${DIR}"

    # keep passwords on reruns (the PostgreSQL volume remembers the old one)
    if [[ -f .env ]]; then
        PGPASS="$(sed -nE 's/^POSTGRES_PASSWORD=//p' .env | head -1)"
        ADMINPW="$(sed -nE 's/^ADMIN_PASSWD=//p' .env | head -1)"
    fi
    PGPASS="${PGPASS:-$(gen_pass 24)}"; ADMINPW="${ADMINPW:-$(gen_pass 20)}"

    cat > .env <<EOF
COMPOSE_PROJECT_NAME=odoo20-${NAME}
INSTANCE=${NAME}
ODOO_CONF_FILE=${CONF_FILE}
HTTP_PORT=${PORT}
PG_VERSION=${PG_VERSION}
POSTGRES_PASSWORD=${PGPASS}
ADMIN_PASSWD=${ADMINPW}
EOF
    chmod 600 .env

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
    image: odoo20-${INSTANCE}:local
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

    # ---- Dockerfile for the instance image (base image + custom pip) ----
    cat > Dockerfile <<'IDOCKER'
FROM odoo20:local
USER root
COPY requirements.txt /tmp/requirements-custom.txt
RUN pip install -r /tmp/requirements-custom.txt
USER odoo
IDOCKER
    printf '*\n!requirements.txt\n!Dockerfile\n' > .dockerignore

    if [[ ! -f requirements.txt ]]; then
        cat > requirements.txt <<'REQ'
# Custom Python packages for this instance (one per line, pip syntax).
# Rerun install_odoo20_docker.sh (or "docker compose build odoo && docker compose up -d")
# to install them into this instance's image. Examples:
#   openpyxl
#   zeep>=4.2
#   git+https://github.com/OCA/some-lib.git@main#egg=some-lib
REQ
    fi
    read -ra _pk <<<"${PIP_EXTRA}"
    for _p in "${_pk[@]}"; do
        grep -qxF "${_p}" requirements.txt || echo "${_p}" >> requirements.txt
    done

    # ---- docker-compose.override.yml: yours to edit, never overwritten ----
    if [[ ! -f docker-compose.override.yml ]]; then
        cat > docker-compose.override.yml <<'OVR'
# Extra settings merged automatically into docker-compose.yml. Example: mount more
# addon folders from anywhere on the host, then list them in addons_path of the .conf:
#
# services:
#   odoo:
#     volumes:
#       - /srv/git/oca-web:/mnt/custom-addons/oca-web
#       - /srv/git/our-modules:/mnt/our-modules
#     environment:
#       TZ: Asia/Kolkata
OVR
    fi

    # ---- Odoo config file (created once; your edits are kept) ----
    # Older version of this script used odoo.conf - adopt it so edits are not lost.
    if [[ ! -f "${CONF_FILE}" && -f odoo.conf ]]; then
        mv odoo.conf "${CONF_FILE}"
        log "[${NAME}] Renamed existing odoo.conf to ${CONF_FILE}"
    fi
    if [[ -f "${CONF_FILE}" && "${RECONFIGURE:-0}" == "1" ]]; then
        cp -a "${CONF_FILE}" "${CONF_FILE}.bak"
        rm -f "${CONF_FILE}"
        log "[${NAME}] Old config saved as ${CONF_FILE}.bak"
    fi
    if [[ ! -f "${CONF_FILE}" ]]; then
        log "[${NAME}] Writing ${CONF_FILE}"
        {
cat <<EOF
[options]
; ---- Odoo ${NAME} instance: edit freely, then: docker compose restart odoo ----
admin_passwd = ${ADMINPW}

; ---- database (created by the install script) ----
db_host = db
db_port = 5432
db_user = odoo
db_password = ${PGPASS}

; ---- custom paths -------------------------------------------------------
; Paths are as seen INSIDE the container:
;   /opt/odoo/addons       standard Odoo addons
;   /mnt/extra-addons      <instance>/addons          (host folder)
;   /mnt/custom-addons     <instance>/custom-addons   (host folder, e.g. git clones)
; Add one entry per addon folder (comma separated), e.g.
;   addons_path = /opt/odoo/addons,/mnt/extra-addons,/mnt/custom-addons/oca-web
; More host folders can be mounted in docker-compose.override.yml
addons_path = /opt/odoo/addons,/mnt/extra-addons,/mnt/custom-addons
data_dir = /var/lib/odoo
; server_wide_modules = base,web

; ---- proxy / workers ----
proxy_mode = True
http_interface = 0.0.0.0
http_port = 8069
gevent_port = 8072
workers = ${WRK}
max_cron_threads = 1
limit_memory_soft = 2147483648
limit_memory_hard = 2684354560
limit_time_cpu = 600
limit_time_real = 1200
EOF
            if [[ -n "${DBN}" ]]; then
                echo "db_name = ${DBN}"
                echo "dbfilter = ^${DBN}\$"
            fi
        } > "${CONF_FILE}"
    else
        log "[${NAME}] Keeping existing ${CONF_FILE} (RECONFIGURE=1 to regenerate)"
    fi
    chmod 644 "${CONF_FILE}"   # parent directory is root-only (700)

    # ---- per-instance image: base image + custom pip packages ----
    log "[${NAME}] Building instance image (custom pip packages from requirements.txt)..."
    local BUILD_OPTS=()
    [[ "${REBUILD}" == "1" ]] && BUILD_OPTS+=(--no-cache)
    $DC build "${BUILD_OPTS[@]}" odoo \
        || die "[${NAME}] Building the instance image failed - check ${DIR}/requirements.txt (pip error is above)."

    # ---- database ----
    log "[${NAME}] Starting PostgreSQL ${PG_VERSION}..."
    $DC stop odoo nginx >/dev/null 2>&1 || true
    $DC up -d --wait db

    if [[ -n "${DBN}" ]]; then
        local EXISTS INIT="f" DEMO_FLAG="--without-demo=all"
        EXISTS="$($DC exec -T db psql -U odoo -d postgres -tAc \
            "SELECT 1 FROM pg_database WHERE datname='${DBN}'" 2>/dev/null | tr -d '[:space:]' || true)"
        if [[ "${EXISTS}" == "1" ]]; then
            INIT="$($DC exec -T db psql -U odoo -d "${DBN}" -tAc \
                "SELECT to_regclass('public.ir_module_module') IS NOT NULL" 2>/dev/null | tr -d '[:space:]' || echo f)"
        fi
        if [[ "${INIT}" == "t" ]]; then
            log "[${NAME}] Database ${DBN} already initialised - keeping it."
            DB_STATUS="existing"
        else
            log "[${NAME}] Creating database ${DBN} and installing base modules (a few minutes)..."
            $DC exec -T db dropdb -U odoo --if-exists "${DBN}"
            $DC exec -T db createdb -U odoo -E UTF8 -T template0 "${DBN}"
            [[ "${DEMO}" == "1" ]] && DEMO_FLAG=""
            $DC run --rm -T odoo -c "/etc/odoo/${CONF_FILE}" -d "${DBN}" -i base ${DEMO_FLAG} \
                --stop-after-init --workers=0 2>&1 | tee "/tmp/odoo20_${NAME}_init.log" \
                || {
                    warn "[${NAME}] Database initialisation failed. First errors in the output (root cause is usually here):"
                    echo "------------------------------------------------------------" >&2
                    awk '/ (ERROR|CRITICAL) /{f=1} f{print; if(++n>=45) exit}' "/tmp/odoo20_${NAME}_init.log" >&2
                    echo "------------------------------------------------------------" >&2
                    die "Initialisation failed - paste the block above. Full output: /tmp/odoo20_${NAME}_init.log"
                }
            DB_STATUS="created"

            WEB_PASSWD="$(gen_pass 16)"
            local SHELL_OUT
            SHELL_OUT="$(cat <<'PYEOF' | $DC run --rm -T -e ODOO_WEB_PW="${WEB_PASSWD}" odoo shell -c "/etc/odoo/${CONF_FILE}" -d "${DBN}" --workers=0 2>&1 || true
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
                log "[${NAME}] Random password set for web user 'admin'."
            else
                WEB_PASSWD="admin"
                warn "[${NAME}] Could not set a random web password - login is admin / admin, CHANGE IT after first login."
            fi
        fi
    fi

    # ---- start & test ----
    log "[${NAME}] Starting Odoo and Nginx..."
    $DC up -d
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        ufw allow "${PORT}/tcp" >/dev/null
    fi

    local ok=0 CODE
    log "[${NAME}] Waiting for Odoo on port ${PORT} (up to 2 minutes)..."
    for _ in $(seq 1 40); do
        if curl -s -o /dev/null "http://127.0.0.1:${PORT}/web/login"; then ok=1; break; fi
        sleep 3
    done
    if [[ ${ok} -ne 1 ]]; then
        warn "[${NAME}] Odoo is not answering. Container status and last log lines:"
        $DC ps || true
        $DC logs --tail 40 odoo nginx || true
        die "[${NAME}] Odoo did not come up - see the output above."
    fi
    CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/web/login" || true)"

    local URL_PORT=""; [[ "${PORT}" != "80" ]] && URL_PORT=":${PORT}"
    local IP; IP="$(hostname -I | awk '{print $1}')"
    local URL="http://${IP}${URL_PORT}"

    umask 077
    cat > "${DIR}/credentials.txt" <<EOF
Instance        : ${NAME}
Odoo URL        : ${URL}
Master password : ${ADMINPW}
Database        : ${DBN:-none} (${DB_STATUS})
Web login       : admin / ${WEB_PASSWD}
PostgreSQL role : odoo / ${PGPASS}   (inside Docker only)
Project dir     : ${DIR}
Config file     : ${DIR}/${CONF_FILE}
Custom pip      : ${DIR}/requirements.txt
EOF
    SUMMARY+=("$(printf '  %-5s %s  (HTTP %s)\n        DB: %s - %s | login: admin / %s' "${NAME^^}" "${URL}" "${CODE}" "${DBN:-none}" "${DB_STATUS}" "${WEB_PASSWD}")")
    cd "${BASE_DIR}"
}

SUMMARY=()
for inst in ${INSTANCES}; do
    case "${inst}" in
        prod) deploy_instance prod "${PROD_PORT}" "${DB_PROD}" "${WORKERS_PROD}" ;;
        uat)  deploy_instance uat  "${UAT_PORT}"  "${DB_UAT}"  "${WORKERS_UAT}" ;;
    esac
done

#--- 5. Helper: refresh UAT from production ----------------------------------
cat > "${BASE_DIR}/refresh_uat_from_prod.sh" <<'REFRESH'
#!/usr/bin/env bash
# Replace the UAT database + filestore with a copy of production, then neutralize
# it (disables outgoing mail, crons, payment providers...). Production is only read.
set -Eeuo pipefail
BASE="__BASE__"; PROD_DB="__PROD_DB__"; UAT_DB="__UAT_DB__"
P="docker compose --project-directory $BASE/prod"
U="docker compose --project-directory $BASE/uat"
[[ $EUID -eq 0 ]] || { echo "Run as root: sudo bash $0" >&2; exit 1; }
read -r -p "This REPLACES UAT database ${UAT_DB} with a copy of ${PROD_DB}. Continue? [y/N] " a
[[ "$a" =~ ^[Yy]$ ]] || exit 1

$U stop odoo nginx
$U up -d --wait db
$U exec -T db dropdb -U odoo --if-exists "$UAT_DB"
$U exec -T db createdb -U odoo -E UTF8 -T template0 "$UAT_DB"
echo "[+] Copying database..."
$P exec -T db pg_dump -U odoo -Fc --no-owner "$PROD_DB" | $U exec -T db pg_restore -U odoo -d "$UAT_DB" --no-owner

if $P exec -T odoo test -d "/var/lib/odoo/filestore/$PROD_DB"; then
    echo "[+] Copying filestore..."
    $P exec -T odoo tar -C /var/lib/odoo/filestore -cf - "$PROD_DB" | \
      $U run --rm -T --no-deps --entrypoint sh odoo -c \
        "mkdir -p /var/lib/odoo/filestore && cd /var/lib/odoo/filestore && rm -rf '$UAT_DB' '$PROD_DB' && tar -xf - && mv '$PROD_DB' '$UAT_DB'"
fi

echo "[+] Neutralizing UAT database..."
$U run --rm -T odoo neutralize -c /etc/odoo/odoo_uat.conf -d "$UAT_DB" \
  || echo "[!] neutralize failed - disable mail servers and scheduled actions in UAT manually!"
$U up -d
echo "[+] UAT now contains a neutralized copy of production. Production passwords/logins apply."
REFRESH
sed -i "s#__BASE__#${BASE_DIR}#; s#__PROD_DB__#${DB_PROD}#; s#__UAT_DB__#${DB_UAT}#" "${BASE_DIR}/refresh_uat_from_prod.sh"
chmod 700 "${BASE_DIR}/refresh_uat_from_prod.sh"

echo
echo "=============================================================="
for line in "${SUMMARY[@]}"; do echo "${line}"; done
echo "--------------------------------------------------------------"
echo "  Secrets   : ${BASE_DIR}/prod/credentials.txt, ${BASE_DIR}/uat/credentials.txt"
echo "  Logs      : cd ${BASE_DIR}/<prod|uat> && docker compose logs -f odoo"
echo "  Restart   : cd ${BASE_DIR}/<prod|uat> && docker compose restart odoo"
echo "  Stop      : cd ${BASE_DIR}/<prod|uat> && docker compose down"
echo "  Config    : ${BASE_DIR}/prod/odoo_production.conf  |  ${BASE_DIR}/uat/odoo_uat.conf"
echo "  Addons    : <instance>/addons and <instance>/custom-addons (see addons_path in the .conf)"
echo "  Custom pip: <instance>/requirements.txt, then rerun this script (or: docker compose build odoo)"
echo "  UAT copy  : sudo bash ${BASE_DIR}/refresh_uat_from_prod.sh"
echo "=============================================================="
