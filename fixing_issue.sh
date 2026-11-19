#!/usr/bin/env bash
#=============================================================================
# enable_https_odoo20.sh - adds HTTPS to the stack made by install_odoo20_single.sh
#
#  * Fixes: "Cannot read properties of undefined (reading 'writeText')"
#    (browsers only allow the clipboard API on HTTPS / localhost)
#  * No domain?  -> self-signed certificate for the server IP (browser shows a
#                   one-time warning; after accepting it, clipboard works)
#  * Have a domain? -> free Let's Encrypt certificate (DOMAIN=... EMAIL=...)
#  * Replaces the default admin/admin web password with a random one
#  * Sets Odoo's web.base.url to the new https:// address
#  * Safe to re-run. Does NOT touch the installer's nginx.conf (it uses
#    nginx-ssl.conf + docker-compose.override.yml, so rerunning
#    install_odoo20_single.sh keeps HTTPS working).
#
# Usage:
#   sudo bash enable_https_odoo20.sh                      # self-signed, by IP
#   sudo DOMAIN=erp.example.com EMAIL=me@example.com bash enable_https_odoo20.sh
#
# Options (env vars):
#   BASE_DIR=/opt/odoo20-docker
#   HTTPS_PORT=443
#   PUBLIC_IP=69.30.237.236     (auto-detected if empty)
#   DOMAIN= EMAIL=              (Let's Encrypt; DNS must point to this server
#                                and host port 80 must be reachable)
#   FORCE_CERT=1                regenerate the self-signed certificate
#   SET_ADMIN_PW=0              do not touch the admin web password
#   DB_NAME=                    (default: read from odoo.conf)
#=============================================================================
set -Eeuo pipefail
trap 'echo -e "\033[0;31m[x]\033[0m Failed at line $LINENO" >&2' ERR

BASE_DIR="${BASE_DIR:-/opt/odoo20-docker}"
HTTPS_PORT="${HTTPS_PORT:-443}"
PUBLIC_IP="${PUBLIC_IP:-}"
DOMAIN="${DOMAIN:-}"
EMAIL="${EMAIL:-}"
FORCE_CERT="${FORCE_CERT:-0}"
SET_ADMIN_PW="${SET_ADMIN_PW:-1}"
DB_NAME="${DB_NAME:-}"
MARK="# managed-by: enable_https_odoo20.sh"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*" >&2; }
die()  { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }
gen_pass() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-"${1:-16}"; }

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0"
[[ "${HTTPS_PORT}" =~ ^[0-9]+$ ]] || die "HTTPS_PORT must be a number"
[[ -d "${BASE_DIR}" ]] || die "Project folder not found: ${BASE_DIR}"
cd "${BASE_DIR}"
[[ -f docker-compose.yml && -f .env ]] || die "docker-compose.yml / .env missing in ${BASE_DIR}"
command -v openssl &>/dev/null || apt-get install -y openssl
command -v curl    &>/dev/null || apt-get install -y curl
DC="docker compose"

CONF_FILE="$(sed -nE 's/^ODOO_CONF_FILE=//p' .env | head -1)"; CONF_FILE="${CONF_FILE:-odoo.conf}"
HTTP_PORT="$(sed -nE 's/^HTTP_PORT=//p' .env | head -1)";      HTTP_PORT="${HTTP_PORT:-80}"
[[ -f "${CONF_FILE}" ]] || die "${CONF_FILE} not found in ${BASE_DIR}"
if [[ -z "${DB_NAME}" ]]; then
    DB_NAME="$(sed -nE 's/^db_name *= *//p' "${CONF_FILE}" | head -1 | tr -d '[:space:]')"
fi

if [[ "${HTTPS_PORT}" == "${HTTP_PORT}" ]]; then
    die "HTTPS_PORT (${HTTPS_PORT}) equals the HTTP port. Choose another HTTPS_PORT."
fi

# refuse to overwrite a hand-edited override file
if [[ -f docker-compose.override.yml ]] \
   && grep -qvE '^\s*(#|$)' docker-compose.override.yml \
   && ! grep -qF "${MARK}" docker-compose.override.yml; then
    die "docker-compose.override.yml has your own settings. Add the nginx ports/volumes from this script's output manually, or move that file away and rerun."
fi

#--- 1. Host name / IP -------------------------------------------------------
if [[ -z "${PUBLIC_IP}" ]]; then
    PUBLIC_IP="$(curl -s4 --max-time 6 https://ifconfig.me 2>/dev/null || true)"
    [[ "${PUBLIC_IP}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || PUBLIC_IP=""
fi
LOCAL_IPS="$(hostname -I 2>/dev/null || true)"
[[ -n "${PUBLIC_IP}" || -n "${LOCAL_IPS}" ]] || die "Could not detect the server IP. Set PUBLIC_IP=..."
PRIMARY_HOST="${DOMAIN:-${PUBLIC_IP:-$(awk '{print $1}' <<<"${LOCAL_IPS}")}}"

PORT_SUFFIX=""; [[ "${HTTPS_PORT}" != "443" ]] && PORT_SUFFIX=":${HTTPS_PORT}"
URL="https://${PRIMARY_HOST}${PORT_SUFFIX}"
mkdir -p certs

#--- 2. Certificate ----------------------------------------------------------
if [[ -n "${DOMAIN}" ]]; then
    [[ -n "${EMAIL}" ]] || die "Let's Encrypt needs EMAIL=you@example.com"
    [[ "${HTTP_PORT}" == "80" ]] || die "Let's Encrypt needs host port 80 (HTTP_PORT in .env is ${HTTP_PORT})."
    log "Requesting a Let's Encrypt certificate for ${DOMAIN}..."
    mkdir -p letsencrypt
    $DC stop nginx >/dev/null 2>&1 || true
    docker run --rm -p 80:80 -v "${BASE_DIR}/letsencrypt:/etc/letsencrypt" certbot/certbot \
        certonly --standalone --non-interactive --agree-tos \
        -m "${EMAIL}" -d "${DOMAIN}" --keep-until-expiring \
        || die "Let's Encrypt failed. Check that ${DOMAIN} points to this server and port 80 is open in your firewall / cloud security group."
    cp -L "letsencrypt/live/${DOMAIN}/fullchain.pem" certs/fullchain.pem
    cp -L "letsencrypt/live/${DOMAIN}/privkey.pem"   certs/privkey.pem

    cat > renew_cert.sh <<RENEW
#!/usr/bin/env bash
# renews the Let's Encrypt certificate (needs port 80 briefly)
set -e
cd "${BASE_DIR}"
docker compose stop nginx
docker run --rm -p 80:80 -v "${BASE_DIR}/letsencrypt:/etc/letsencrypt" certbot/certbot renew --standalone --quiet || true
cp -L "letsencrypt/live/${DOMAIN}/fullchain.pem" certs/fullchain.pem
cp -L "letsencrypt/live/${DOMAIN}/privkey.pem"   certs/privkey.pem
docker compose start nginx
RENEW
    chmod 700 renew_cert.sh
    echo "17 3 * * 1 root ${BASE_DIR}/renew_cert.sh >>/var/log/odoo20-cert-renew.log 2>&1" > /etc/cron.d/odoo20-cert-renew
    chmod 644 /etc/cron.d/odoo20-cert-renew
    log "Certificate installed; weekly renewal job added (/etc/cron.d/odoo20-cert-renew)."
    CERT_KIND="Let's Encrypt (trusted)"
else
    if [[ ! -f certs/fullchain.pem || "${FORCE_CERT}" == "1" ]]; then
        log "Creating a self-signed certificate (valid 825 days)..."
        SAN="IP:127.0.0.1"
        [[ -n "${PUBLIC_IP}" ]] && SAN="${SAN},IP:${PUBLIC_IP}"
        for ip in ${LOCAL_IPS}; do
            [[ "${ip}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && SAN="${SAN},IP:${ip}"
        done
        openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
            -keyout certs/privkey.pem -out certs/fullchain.pem \
            -subj "/CN=${PRIMARY_HOST}" -addext "subjectAltName=${SAN}" 2>/dev/null
    else
        log "Keeping existing certificate in certs/ (FORCE_CERT=1 to recreate)."
    fi
    CERT_KIND="self-signed (browser warns once)"
fi
chmod 600 certs/privkey.pem
chmod 644 certs/fullchain.pem

#--- 3. Nginx HTTPS config ---------------------------------------------------
log "Writing nginx-ssl.conf"
cat > nginx-ssl.conf <<'NGINXCONF'
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

upstream odoo_backend   { server odoo:8069; }
upstream odoo_websocket { server odoo:8072; }

# plain HTTP -> HTTPS
server {
    listen 80;
    server_name _;
    return 301 https://$host__PORT_SUFFIX__$request_uri;
}

server {
    listen 443 ssl;
    http2 on;
    server_name _;

    ssl_certificate     /etc/nginx/certs/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;

    client_max_body_size 200m;
    proxy_read_timeout    720s;
    proxy_connect_timeout 720s;
    proxy_send_timeout    720s;

    proxy_set_header Host              $http_host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
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
sed -i "s|__PORT_SUFFIX__|${PORT_SUFFIX}|" nginx-ssl.conf

#--- 4. Compose override -----------------------------------------------------
log "Writing docker-compose.override.yml"
cat > docker-compose.override.yml <<OVR
${MARK}
# Re-run enable_https_odoo20.sh to regenerate. Add your own settings below the services.
services:
  nginx:
    ports:
      - "${HTTPS_PORT}:443"
    volumes:
      - ./nginx-ssl.conf:/etc/nginx/conf.d/default.conf:ro
      - ./certs:/etc/nginx/certs:ro
OVR

#--- 5. Firewall -------------------------------------------------------------
if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    ufw allow "${HTTPS_PORT}/tcp" >/dev/null
    log "ufw: opened ${HTTPS_PORT}/tcp"
fi

#--- 6. Restart Nginx --------------------------------------------------------
log "Restarting Nginx..."
$DC up -d --force-recreate nginx
sleep 3
$DC exec -T nginx nginx -t >/dev/null 2>&1 || {
    $DC logs --tail 40 nginx >&2 || true
    die "Nginx config test failed - see output above."
}

ok=0
for _ in $(seq 1 40); do
    if curl -skf -o /dev/null "https://127.0.0.1:${HTTPS_PORT}/web/login"; then ok=1; break; fi
    sleep 3
done
if [[ ${ok} -ne 1 ]]; then
    $DC ps || true
    $DC logs --tail 50 odoo nginx || true
    die "HTTPS did not answer on port ${HTTPS_PORT}."
fi
log "HTTPS is working locally on port ${HTTPS_PORT}."

#--- 7. Odoo: base URL + admin password ---------------------------------------
NEWPW=""
if [[ -n "${DB_NAME}" ]]; then
    [[ "${DB_NAME}" =~ ^[A-Za-z0-9_]+$ ]] || die "Invalid DB_NAME: ${DB_NAME}"
    [[ "${SET_ADMIN_PW}" == "1" ]] && NEWPW="$(gen_pass 16)"
    log "Updating web.base.url and checking the admin password..."
    OUT="$(cat <<'PYEOF' | $DC run --rm -T -e ODOO_BASE_URL="${URL}" -e ODOO_NEW_PW="${NEWPW}" odoo shell -c "/etc/odoo/${CONF_FILE}" -d "${DB_NAME}" --workers=0 2>&1 || true
import os
icp = env['ir.config_parameter'].sudo()
icp.set_param('web.base.url', os.environ['ODOO_BASE_URL'])
icp.set_param('web.base.url.freeze', 'True')
print('BASEURL_OK')
newpw = os.environ.get('ODOO_NEW_PW')
if newpw:
    u = env.ref('base.user_admin')
    try:
        u._check_credentials({'type': 'password', 'password': 'admin'}, {'interactive': False})
        default_pw = True
    except Exception:
        default_pw = False
    if default_pw:
        u.write({'password': newpw})
        print('PW_CHANGED')
    else:
        print('PW_ALREADY_CUSTOM')
env.cr.commit()
PYEOF
)"
    grep -q BASEURL_OK <<<"${OUT}" && log "web.base.url set to ${URL}" \
        || warn "Could not set web.base.url automatically (set it in Settings > Technical > System Parameters)."
    if grep -q PW_CHANGED <<<"${OUT}"; then
        log "Default admin password replaced."
        if [[ -f credentials.txt ]]; then
            sed -i "s|^Web login .*|Web login       : admin / ${NEWPW}|" credentials.txt
        fi
    else
        NEWPW=""
        grep -q PW_ALREADY_CUSTOM <<<"${OUT}" && log "Admin password is already custom - left unchanged."
    fi
else
    warn "No db_name found in ${CONF_FILE}; skipped base URL / password step."
fi
[[ -f credentials.txt ]] && sed -i "s|^Odoo URL .*|Odoo URL        : ${URL}|" credentials.txt || true

echo
echo "=============================================================="
echo "  HTTPS URL   : ${URL}"
echo "  Certificate : ${CERT_KIND}"
[[ -n "${NEWPW}" ]] && echo "  New login   : admin / ${NEWPW}   (saved in credentials.txt)"
echo "--------------------------------------------------------------"
if [[ -z "${DOMAIN}" ]]; then
echo "  Open the URL above; Chrome shows 'Your connection is not private'."
echo "  Click Advanced > Proceed. The clipboard button works after that."
fi
echo "  If the page does not open, allow TCP ${HTTPS_PORT} in your cloud"
echo "  provider's firewall / security group."
echo "  Logs: cd ${BASE_DIR} && docker compose logs -f nginx odoo"
echo "=============================================================="
