#!/bin/bash
# =============================================================
# ZapTec SaaS - Instalador completo para VPS
# Compativel com: Ubuntu 22.04+, Debian 12+, AlmaLinux 8+, Rocky Linux 8+
#
# INSTALAR (interativo):
#   curl -sSL https://raw.githubusercontent.com/morrice22/zaptec-install/main/install.sh | sudo bash
#
# INSTALAR (silencioso):
#   APP_DOMAIN=app.meusite.com APP_PORT=3000 USE_CERTBOT=no \
#   ADMIN_EMAIL=admin@meusite.com ADMIN_PASS=SenhaForte123 \
#   GITHUB_TOKEN=ghp_xxx \
#   curl -sSL .../install.sh | sudo bash
#
# USE_CERTBOT=yes  → Nginx + Let's Encrypt (porta interna APP_PORT)
# USE_CERTBOT=no   → Sem Nginx/Certbot (proxy reverso ou acesso direto na APP_PORT)
#
# ATUALIZAR:
#   curl -sSL .../update.sh | sudo bash
# =============================================================

set -euo pipefail

GITHUB_USER="morrice22"
GITHUB_REPO="whatsapp-saas"
GITHUB_BRANCH="main"

INSTALL_DIR="/opt/zaptec"
REPO_URL="https://github.com/${GITHUB_USER}/${GITHUB_REPO}.git"
TICKETZ_PROXY_PORT=8899

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${GREEN}[+]${NC} $1"; }
info()    { echo -e "${BLUE}[i]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[x]${NC} $1"; exit 1; }
section() { echo -e "\n${BOLD}${CYAN}==> $1${NC}"; }

# Executa um comando LONGO (que roda em silêncio) mostrando um spinner animado,
# para o instalador não parecer travado. Em erro, mostra as últimas linhas do log.
#   Uso: run_step "Descrição" comando arg1 arg2 ...
run_step() {
  local desc="$1"; shift
  local logfile; logfile="$(mktemp 2>/dev/null || echo /tmp/zaptec-step.$$)"
  local tty=""; { : >/dev/tty; } 2>/dev/null && tty="/dev/tty"
  [[ -z "$tty" ]] && printf "  [ ] %s ...\n" "$desc"
  "$@" >"$logfile" 2>&1 &
  local pid=$!
  if [[ -n "$tty" ]]; then
    local frames='|/-\' i=0
    while kill -0 "$pid" 2>/dev/null; do
      printf "\r  ${CYAN}[%s]${NC} %s " "${frames:$((i%4)):1}" "$desc" >"$tty"
      i=$((i+1)); sleep 0.2
    done
  fi
  if wait "$pid"; then
    if [[ -n "$tty" ]]; then printf "\r  ${GREEN}[+]${NC} %s        \n" "$desc" >"$tty"; else printf "  [+] %s\n" "$desc"; fi
    rm -f "$logfile"
  else
    if [[ -n "$tty" ]]; then printf "\r  ${RED}[x]${NC} %s        \n" "$desc" >"$tty"; else printf "  [x] %s\n" "$desc"; fi
    echo -e "${RED}  --- últimas linhas do erro ---${NC}" >&2
    tail -n 25 "$logfile" >&2
    rm -f "$logfile"
    exit 1
  fi
}

ask() {
  local var="$1" prompt="$2" default="${3:-}"
  if [[ -n "${!var:-}" ]]; then return; fi
  if [[ -n "$default" ]]; then
    printf "%b" "${BOLD}${prompt}${NC}" >/dev/tty
    read -r "$var" </dev/tty
    if [[ -z "${!var:-}" ]]; then printf -v "$var" "%s" "$default"; fi
  else
    printf "%b" "${BOLD}${prompt}${NC}" >/dev/tty
    read -r "$var" </dev/tty
  fi
}

ask_secret() {
  local var="$1" prompt="$2"
  if [[ -n "${!var:-}" ]]; then return; fi
  printf "%b" "${BOLD}${prompt}${NC}" >/dev/tty
  read -rs "$var" </dev/tty
  echo >/dev/tty
}

is_yes() {
  local v="${1,,}"
  [[ "$v" =~ ^(s|sim|y|yes|1|true)$ ]]
}

# ── Deteccao Ticketz (para aba Migracao no painel) ───────────
HAS_TICKETZ=false
TICKETZ_DIR=""
TICKETZ_ENV=""
TICKETZ_DB_CONTAINER=""
TICKETZ_DB_NAME=""
TICKETZ_DB_USER=""
TICKETZ_DB_PASS=""
TICKETZ_DB_HOST=""
TICKETZ_DB_PORT="5432"
TICKETZ_DB_DOCKER_HOST="postgres"
TICKETZ_MEDIA_BASE_URL=""

detect_ticketz() {
  for dir in /opt/ticketz /opt/whaticket /opt/ticketzsaas /home/deploy/ticketz /root/ticketz /var/www/ticketz; do
    if [[ -f "$dir/.env" || -f "$dir/docker-compose.yml" || -f "$dir/docker-compose.yaml" ]]; then
      TICKETZ_DIR="$dir"
      TICKETZ_ENV="$dir/.env"
      HAS_TICKETZ=true
      return 0
    fi
  done

  local c
  c=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -iE 'ticketz|whaticket' | head -1 || true)
  if [[ -n "$c" ]]; then
    HAS_TICKETZ=true
    TICKETZ_DIR=$(docker inspect "$c" --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null || echo "")
    if [[ -f "$TICKETZ_DIR/.env" ]]; then
      TICKETZ_ENV="$TICKETZ_DIR/.env"
    fi
  fi
  return 0
}

read_ticketz_db_credentials() {
  [[ "$HAS_TICKETZ" != true ]] && return 0
  [[ -n "$TICKETZ_ENV" && -f "$TICKETZ_ENV" ]] || return 0

  local db_url
  db_url=$(grep -E '^DATABASE_URL=' "$TICKETZ_ENV" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || true)
  if [[ -n "$db_url" ]]; then
    TICKETZ_DB_USER=$(echo "$db_url" | sed 's|.*://||;s|:.*||')
    TICKETZ_DB_PASS=$(echo "$db_url" | sed 's|.*://[^:]*:||;s|@.*||')
    TICKETZ_DB_HOST=$(echo "$db_url" | sed 's|.*@||;s|:.*||;s|/.*||')
    TICKETZ_DB_PORT=$(echo "$db_url" | sed -n 's|.*:\([0-9]*\)/.*|\1|p')
    TICKETZ_DB_NAME=$(echo "$db_url" | sed 's|.*/||;s|?.*||')
    [[ -z "$TICKETZ_DB_PORT" ]] && TICKETZ_DB_PORT="5432"
  else
    TICKETZ_DB_HOST=$(grep -E '^DB_HOST=' "$TICKETZ_ENV" 2>/dev/null | cut -d'=' -f2 | tr -d '"' || echo "localhost")
    TICKETZ_DB_PORT=$(grep -E '^DB_PORT=' "$TICKETZ_ENV" 2>/dev/null | cut -d'=' -f2 | tr -d '"' || echo "5432")
    TICKETZ_DB_USER=$(grep -E '^DB_USER=' "$TICKETZ_ENV" 2>/dev/null | cut -d'=' -f2 | tr -d '"' || echo "postgres")
    TICKETZ_DB_PASS=$(grep -E '^DB_PASS=' "$TICKETZ_ENV" 2>/dev/null | cut -d'=' -f2 | tr -d '"' || echo "")
    TICKETZ_DB_NAME=$(grep -E '^DB_NAME=' "$TICKETZ_ENV" 2>/dev/null | cut -d'=' -f2 | tr -d '"' || echo "ticketz")
  fi

  TICKETZ_DB_CONTAINER=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -iE 'postgres|postgresql|ticketz.*db|db.*ticketz' | head -1 || true)

  local compose="$TICKETZ_DIR/docker-compose.yml"
  [[ -f "$TICKETZ_DIR/docker-compose.yaml" ]] && compose="$TICKETZ_DIR/docker-compose.yaml"
  if [[ -f "$compose" ]]; then
    local svc
    svc=$(grep -E 'image:.*postgres' "$compose" -B 20 2>/dev/null | grep -E '^[[:space:]]{2}[a-zA-Z0-9_.-]+:' | tail -1 | sed 's/://g; s/^[[:space:]]*//' || true)
    [[ -n "$svc" ]] && TICKETZ_DB_DOCKER_HOST="$svc"
  fi

  local backend_url
  backend_url=$(grep -E '^BACKEND_URL=' "$TICKETZ_ENV" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || true)
  [[ -z "$backend_url" ]] && backend_url=$(grep -E '^REACT_APP_BACKEND_URL=' "$TICKETZ_ENV" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || true)
  [[ -n "$backend_url" ]] && TICKETZ_MEDIA_BASE_URL="${backend_url%/}"

  [[ -z "$TICKETZ_MEDIA_BASE_URL" && -d "$TICKETZ_DIR/public/media" ]] && warn "Ticketz: mídia local em $TICKETZ_DIR/public/media — configure TICKETZ_MEDIA_BASE_URL depois se a migração de arquivos falhar."
}

setup_ticketz_proxy() {
  [[ "$HAS_TICKETZ" != true ]] && return 0
  [[ -f "$INSTALL_DIR/deploy/ticketz-proxy.js" ]] || { warn "ticketz-proxy.js não encontrado — migração via painel indisponível."; return 0; }

  section "Migração Ticketz (proxy local)"
  read_ticketz_db_credentials

  TICKETZ_PROXY_TOKEN="${TICKETZ_PROXY_TOKEN:-$(openssl rand -hex 16)}"
  docker stop ticketz-mig-proxy 2>/dev/null || true
  docker rm ticketz-mig-proxy 2>/dev/null || true

  local proxy_js="$INSTALL_DIR/deploy/ticketz-proxy.js"
  local run_ok=false

  if [[ -n "$TICKETZ_DB_CONTAINER" ]]; then
    local network
    network=$(docker inspect "$TICKETZ_DB_CONTAINER" -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' | head -1)
    if [[ -n "$network" ]]; then
      info "Subindo proxy na rede Docker: $network (host DB: $TICKETZ_DB_DOCKER_HOST)"
      if docker run -d --name ticketz-mig-proxy \
        --restart unless-stopped \
        --network "$network" \
        -p "127.0.0.1:${TICKETZ_PROXY_PORT}:8899" \
        -e "PROXY_TOKEN=${TICKETZ_PROXY_TOKEN}" \
        -e "DB_HOST=${TICKETZ_DB_DOCKER_HOST}" \
        -e "DB_PORT=${TICKETZ_DB_PORT}" \
        -e "DB_NAME=${TICKETZ_DB_NAME}" \
        -e "DB_USER=${TICKETZ_DB_USER}" \
        -e "DB_PASS=${TICKETZ_DB_PASS}" \
        -v "${proxy_js}:/app/proxy.js:ro" \
        node:20-alpine sh -c "cd /app && npm i pg --no-save --silent 2>/dev/null && node proxy.js" 2>/dev/null; then
        run_ok=true
      fi
    fi
  fi

  if [[ "$run_ok" != true && -n "$TICKETZ_DB_HOST" ]]; then
    info "Subindo proxy apontando para Postgres em ${TICKETZ_DB_HOST}:${TICKETZ_DB_PORT}"
    if docker run -d --name ticketz-mig-proxy \
      --restart unless-stopped \
      --add-host=host.docker.internal:host-gateway \
      -p "127.0.0.1:${TICKETZ_PROXY_PORT}:8899" \
      -e "PROXY_TOKEN=${TICKETZ_PROXY_TOKEN}" \
      -e "DB_HOST=${TICKETZ_DB_HOST}" \
      -e "DB_PORT=${TICKETZ_DB_PORT}" \
      -e "DB_NAME=${TICKETZ_DB_NAME}" \
      -e "DB_USER=${TICKETZ_DB_USER}" \
      -e "DB_PASS=${TICKETZ_DB_PASS}" \
      -v "${proxy_js}:/app/proxy.js:ro" \
      node:20-alpine sh -c "cd /app && npm i pg --no-save --silent 2>/dev/null && node proxy.js" 2>/dev/null; then
      run_ok=true
    fi
  fi

  if [[ "$run_ok" == true ]]; then
    sleep 2
    TICKETZ_PROXY_URL="http://127.0.0.1:${TICKETZ_PROXY_PORT}/"
    log "Proxy Ticketz ativo em ${TICKETZ_PROXY_URL} (aba Migração no painel SUPER_ADMIN)"
    info "Ticketz detectado em: ${TICKETZ_DIR:-container Docker}"
  else
    warn "Não foi possível iniciar o proxy Ticketz automaticamente."
    warn "Configure manualmente (deploy/MIGRATION-TICKETZ.md) e adicione TICKETZ_PROXY_URL ao .env"
    TICKETZ_PROXY_URL=""
    TICKETZ_PROXY_TOKEN=""
  fi
}

write_nginx_config() {
  local conf="$1" domain="$2" port="$3" ssl="$4"
  if [[ "$ssl" == "true" ]]; then
    cat > "$conf" <<NGINXEOF
server {
    listen 80;
    server_name ${domain};
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name ${domain};
    ssl_certificate     /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_session_cache shared:SSL:10m;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options SAMEORIGIN;
    add_header X-Content-Type-Options nosniff;
    root ${INSTALL_DIR}/frontend/dist;
    index index.html;
    location = /manifest.json {
        proxy_pass http://127.0.0.1:${port};
        proxy_set_header Host \$host;
        add_header Cache-Control "no-cache, no-store, must-revalidate" always;
    }
    location /api/ {
        proxy_pass http://127.0.0.1:${port};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        client_max_body_size 50m;
    }
    location /socket.io/ {
        proxy_pass http://127.0.0.1:${port};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 3600s;
    }
    location /media/ {
        proxy_pass http://127.0.0.1:${port};
        client_max_body_size 50m;
    }
    location /uploads/ {
        proxy_pass http://127.0.0.1:${port};
        client_max_body_size 20m;
    }
    location /webhooks/ {
        proxy_pass http://127.0.0.1:${port};
        proxy_set_header Host \$host;
    }
    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
NGINXEOF
  else
    cat > "$conf" <<NGINXEOF
server {
    listen 80;
    server_name ${domain};
    root ${INSTALL_DIR}/frontend/dist;
    index index.html;
    location = /manifest.json {
        proxy_pass http://127.0.0.1:${port};
        proxy_set_header Host \$host;
        add_header Cache-Control "no-cache, no-store, must-revalidate" always;
    }
    location /api/ {
        proxy_pass http://127.0.0.1:${port};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        client_max_body_size 50m;
    }
    location /socket.io/ {
        proxy_pass http://127.0.0.1:${port};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 3600s;
    }
    location /media/ {
        proxy_pass http://127.0.0.1:${port};
        client_max_body_size 50m;
    }
    location /uploads/ {
        proxy_pass http://127.0.0.1:${port};
        client_max_body_size 20m;
    }
    location /webhooks/ {
        proxy_pass http://127.0.0.1:${port};
        proxy_set_header Host \$host;
    }
    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
NGINXEOF
  fi
}

echo -e "\n${BOLD}${CYAN}"
echo "  +--------------------------------------------------+"
echo "  |       ZapTec SaaS - Instalador VPS v3.0         |"
echo "  +--------------------------------------------------+"
echo -e "${NC}"

# -------------------------------------------------------------
section "Verificacoes"
# -------------------------------------------------------------
[[ $EUID -ne 0 ]] && error "Execute como root: curl ... | sudo bash"
[[ $(uname -m) != "x86_64" ]] && error "Apenas x86_64 suportado."

. /etc/os-release
OS_ID="${ID:-}"
# VERSION_ID pode não existir (ex.: Debian testing/sid); com `set -u` isso abortaria.
OS_VER="${VERSION_ID:-0}"; OS_VER="${OS_VER%%.*}"

if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then
  OS_FAMILY="debian"
elif [[ "$OS_ID" == "almalinux" || "$OS_ID" == "rhel" || "$OS_ID" == "centos" || "$OS_ID" == "rocky" ]]; then
  OS_FAMILY="rhel"
else
  error "Sistema nao suportado: $OS_ID. Use: Ubuntu, Debian, AlmaLinux, Rocky Linux ou RHEL."
fi

log "Sistema detectado: $OS_ID ${VERSION_ID:-?} ($OS_FAMILY)"

detect_ticketz || true
if [[ "$HAS_TICKETZ" == true ]]; then
  info "Ticketz detectado — o instalador configurará o proxy para a aba de Migração"
else
  info "Ticketz não detectado neste servidor"
fi

# -------------------------------------------------------------
section "Configuracao"
# -------------------------------------------------------------
ask APP_DOMAIN  "Dominio publico (ex: app.meusite.com.br): "
ask APP_PORT    "Porta do backend ZapTec [3000]: " "3000"
ask USE_CERTBOT "Configurar Nginx + SSL (Certbot) neste servidor? (s/N) [N]: " "n"
ask APP_NAME    "Nome da aplicacao [ZapTec]: " "ZapTec"
ask ADMIN_EMAIL "E-mail do administrador master: "
ask_secret ADMIN_PASS "Senha do administrador master (min. 8 caracteres): "

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  printf "%b" "${BOLD}GitHub Personal Access Token (repo privado): ${NC}" >/dev/tty
  read -rs GITHUB_TOKEN </dev/tty || GITHUB_TOKEN=""
  echo >/dev/tty
fi

[[ -z "${APP_DOMAIN:-}" ]]   && error "Dominio obrigatorio."
[[ -z "${APP_PORT:-}" ]]     && APP_PORT=3000
[[ ! "$APP_PORT" =~ ^[0-9]+$ ]] || (( APP_PORT < 1024 || APP_PORT > 65535 )) && error "Porta invalida (use 1024-65535)."
[[ -z "${ADMIN_EMAIL:-}" ]]  && error "E-mail do admin obrigatorio."
[[ -z "${ADMIN_PASS:-}" ]]   && error "Senha do admin obrigatoria."
[[ -z "${GITHUB_TOKEN:-}" ]] && error "GITHUB_TOKEN obrigatorio."
[[ ${#ADMIN_PASS} -lt 8 ]]   && error "Senha do admin deve ter no minimo 8 caracteres."

CERTBOT_ENABLED=false
if is_yes "$USE_CERTBOT"; then
  CERTBOT_ENABLED=true
  ask LE_EMAIL "E-mail para SSL Lets Encrypt: "
  [[ -z "${LE_EMAIL:-}" ]] && error "E-mail para SSL obrigatorio quando Certbot esta ativo."
else
  ask USE_HTTPS_PUBLIC "URL publica usa HTTPS? (via proxy reverso) (S/n) [S]: " "s"
fi

if [[ "$CERTBOT_ENABLED" == true ]]; then
  PUBLIC_SCHEME="https"
  PUBLIC_URL="https://${APP_DOMAIN}"
else
  if is_yes "${USE_HTTPS_PUBLIC:-s}"; then
    PUBLIC_SCHEME="https"
    PUBLIC_URL="https://${APP_DOMAIN}"
  else
    PUBLIC_SCHEME="http"
    if [[ "$APP_PORT" == "80" ]]; then
      PUBLIC_URL="http://${APP_DOMAIN}"
    else
      PUBLIC_URL="http://${APP_DOMAIN}:${APP_PORT}"
    fi
  fi
fi

DB_PASSWORD=$(openssl rand -base64 32 | tr -d '/+=\n' | head -c 32)
JWT_SECRET=$(openssl rand -base64 48 | tr -d '/+=\n' | head -c 48)
JWT_REFRESH=$(openssl rand -base64 48 | tr -d '/+=\n' | head -c 48)

info "Dominio:      $APP_DOMAIN"
info "Porta:        $APP_PORT"
info "URL publica:  $PUBLIC_URL"
info "Certbot:      $([ "$CERTBOT_ENABLED" == true ] && echo sim || echo nao)"
info "Admin:        $ADMIN_EMAIL"
info "Ticketz:      $([ "$HAS_TICKETZ" == true ] && echo detectado || echo nao encontrado)"

# -------------------------------------------------------------
section "Atualizando Sistema e Instalando Dependencias"
# -------------------------------------------------------------
PKG_NGINX=""
PKG_CERTBOT=""
if [[ "$CERTBOT_ENABLED" == true ]]; then
  PKG_NGINX="nginx"
  PKG_CERTBOT="certbot python3-certbot-nginx"
fi

if [[ "$OS_FAMILY" == "debian" ]]; then
  export DEBIAN_FRONTEND=noninteractive
  run_step "Atualizando índice de pacotes (apt update)" apt-get update -qq
  run_step "Atualizando o sistema (apt upgrade)" apt-get upgrade -y -qq
  run_step "Instalando dependências base do sistema" apt-get install -y -qq curl wget git openssl ca-certificates gnupg lsb-release ufw fail2ban postgresql postgresql-contrib redis-server $PKG_NGINX $PKG_CERTBOT
else
  rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-AlmaLinux 2>/dev/null || \
  rpm --import https://repo.almalinux.org/almalinux/RPM-GPG-KEY-AlmaLinux 2>/dev/null || true
  dnf upgrade -y -q --nogpgcheck 2>/dev/null || dnf upgrade -y -q || true
  dnf install -y -q epel-release
  # --allowerasing: EL9 traz "curl-minimal" pré-instalado, que conflita com o
  # pacote "curl" completo — deixa o dnf trocar um pelo outro em vez de falhar.
  dnf install -y -q --allowerasing curl wget git openssl ca-certificates gnupg2 \
    firewalld fail2ban postgresql-server postgresql-contrib redis $PKG_NGINX $PKG_CERTBOT
fi
log "Sistema atualizado"

# -------------------------------------------------------------
section "Instalando Node.js 20 LTS e PM2"
# -------------------------------------------------------------
NODE_VER=0; command -v node &>/dev/null && NODE_VER=$(node -v | cut -d. -f1 | tr -d 'v')
if [[ $NODE_VER -lt 20 ]]; then
  if [[ "$OS_FAMILY" == "debian" ]]; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null 2>&1
    run_step "Instalando o Node.js 20 LTS" apt-get install -y -qq nodejs
  else
    curl -fsSL https://rpm.nodesource.com/setup_20.x | bash - >/dev/null 2>&1
    run_step "Instalando o Node.js 20 LTS" dnf install -y -q nodejs
  fi
fi
log "Node.js: $(node -v)"
run_step "Instalando o PM2" npm install -g pm2
log "PM2: $(pm2 --version)"

# -------------------------------------------------------------
section "Clonando Repositorio"
# -------------------------------------------------------------
[[ -d "$INSTALL_DIR" ]] && mv "$INSTALL_DIR" "${INSTALL_DIR}_bkp_$(date +%Y%m%d%H%M%S)"

CLONE_URL="https://${GITHUB_TOKEN}@github.com/${GITHUB_USER}/${GITHUB_REPO}.git"
git clone --depth 1 --branch "$GITHUB_BRANCH" "$CLONE_URL" "$INSTALL_DIR"
log "Repositorio clonado em $INSTALL_DIR"
cd "$INSTALL_DIR"

# Proxy Ticketz (precisa do arquivo no repo)
setup_ticketz_proxy

# -------------------------------------------------------------
section "Criando .env"
# -------------------------------------------------------------
cat > "$INSTALL_DIR/.env" <<ENVEOF
# ZapTec SaaS - Gerado em $(date '+%d/%m/%Y %H:%M') - NAO SUBA PARA O GITHUB!
NODE_ENV=production
PORT=${APP_PORT}
API_URL=${PUBLIC_URL}
BACKEND_URL=${PUBLIC_URL}
DATABASE_URL=postgresql://zaptec:${DB_PASSWORD}@127.0.0.1:5433/zaptec_prod?schema=public
REDIS_HOST=127.0.0.1
REDIS_PORT=6379
REDIS_PASSWORD=
JWT_SECRET=${JWT_SECRET}
JWT_EXPIRES_IN=7d
JWT_REFRESH_SECRET=${JWT_REFRESH}
JWT_REFRESH_EXPIRES_IN=30d
WHATSAPP_SESSIONS_DIR=${INSTALL_DIR}/whatsapp-sessions
WHATSAPP_MEDIA_DIR=${INSTALL_DIR}/public/media
WHATSAPP_SYNC_HISTORY_ON_CONNECT=false
WHATSAPP_SYNC_HISTORY_MAX=20
WHATSAPP_SYNC_HISTORY_DELAY_MS=800
WHATSAPP_MIN_SEND_INTERVAL_MS=1000
CORS_ORIGIN=${PUBLIC_URL}
DEFAULT_MAX_CONNECTIONS=3
DEFAULT_MAX_USERS=5
PM2_RELOAD_COMMAND=pm2 restart zaptec-backend --update-env
GOOGLE_CLIENT_ID=
GOOGLE_CLIENT_SECRET=
GOOGLE_REDIRECT_URI=${PUBLIC_URL}/api/backup/google/callback
ENVEOF

if [[ -n "${TICKETZ_PROXY_URL:-}" ]]; then
  cat >> "$INSTALL_DIR/.env" <<ENVEOF

# Migração Ticketz (aba SUPER_ADMIN → Migração; edite também em Configurações → Sistema → .env)
TICKETZ_PROXY_URL=${TICKETZ_PROXY_URL}
TICKETZ_PROXY_TOKEN=${TICKETZ_PROXY_TOKEN}
TICKETZ_MEDIA_BASE_URL=${TICKETZ_MEDIA_BASE_URL}
MIG_MSG_BATCH_SIZE=2000
MIG_MSG_INSERT_CHUNK=500
ENVEOF
fi

chmod 600 "$INSTALL_DIR/.env"
log ".env criado (porta ${APP_PORT}, URL ${PUBLIC_URL})"

cat > "$INSTALL_DIR/.install-meta" <<METAEOF
APP_DOMAIN=${APP_DOMAIN}
APP_PORT=${APP_PORT}
PUBLIC_URL=${PUBLIC_URL}
USE_CERTBOT=$([ "$CERTBOT_ENABLED" == true ] && echo yes || echo no)
HAS_TICKETZ=$([ "$HAS_TICKETZ" == true ] && echo yes || echo no)
TICKETZ_PROXY_PORT=${TICKETZ_PROXY_PORT}
INSTALLED_AT=$(date -Iseconds)
METAEOF
chmod 600 "$INSTALL_DIR/.install-meta"

# -------------------------------------------------------------
section "Configurando PostgreSQL e Redis (nativos)"
# -------------------------------------------------------------
# Postgres/Redis rodam nativos via systemd, NAO em Docker: um container pode
# ser removido/recriado e abandonar o volume de dados sem ninguem perceber
# (foi exatamente isso que causou perda de acesso ao banco em producao). Porta
# 5433 (nao a 5432 padrao) para nao colidir com um Postgres de Ticketz que
# porventura ja rode em Docker no mesmo host.
if [[ "$OS_FAMILY" == "debian" ]]; then
  PG_VER=$(ls /etc/postgresql/ 2>/dev/null | sort -Vr | head -1)
  [[ -z "$PG_VER" ]] && error "Não encontrei a versão instalada do PostgreSQL em /etc/postgresql/"
  pg_conftool "$PG_VER" main set port 5433
  # Força scram-sha-256 explicitamente (não depender do default de cada versão
  # do pacote): senão o hash da senha e o método exigido no pg_hba podem não
  # bater e a autenticação falha mesmo com a senha certa.
  pg_conftool "$PG_VER" main set password_encryption scram-sha-256
  systemctl enable postgresql --now
  systemctl restart postgresql
  systemctl enable redis-server --now
else
  if [[ ! -s /var/lib/pgsql/data/PG_VERSION ]]; then
    run_step "Inicializando o banco (initdb)" postgresql-setup --initdb
  fi
  PG_CONF=/var/lib/pgsql/data/postgresql.conf
  PG_HBA=/var/lib/pgsql/data/pg_hba.conf
  sed -i "s/^#\?port = .*/port = 5433/" "$PG_CONF"
  # AlmaLinux/RHEL (ex.: PG13) ainda default para md5 — força scram-sha-256
  # para bater com o método exigido abaixo no pg_hba (senão a autenticação
  # falha mesmo com a senha certa, porque o hash salvo é de outro tipo).
  echo "password_encryption = scram-sha-256" >> "$PG_CONF"
  sed -i -E 's/^(host[[:space:]]+all[[:space:]]+all[[:space:]]+(127\.0\.0\.1\/32|::1\/128)[[:space:]]+)ident/\1scram-sha-256/' "$PG_HBA"
  systemctl enable postgresql --now
  systemctl restart postgresql
  systemctl enable redis --now
fi
log "PostgreSQL e Redis nativos ativos (porta do banco: 5433)"

info "Aguardando PostgreSQL aceitar conexões..."
for i in {1..30}; do
  su postgres -c "pg_isready -p 5433" &>/dev/null && break || sleep 1
done

# Recria role e banco do zero (instalação sempre parte de um estado limpo,
# igual ao comportamento anterior do container Docker recém-criado).
# 'su' (não 'sudo') porque o script já roda como root e nem toda VPS tem o
# pacote sudo instalado.
su postgres -c "psql -p 5433 -v ON_ERROR_STOP=1" >/dev/null <<SQL
DROP DATABASE IF EXISTS zaptec_prod;
DROP ROLE IF EXISTS zaptec;
CREATE ROLE zaptec LOGIN PASSWORD '${DB_PASSWORD}';
CREATE DATABASE zaptec_prod OWNER zaptec;
SQL
log "Role 'zaptec' e banco 'zaptec_prod' criados"

info "Aguardando banco ficar pronto..."
for i in {1..30}; do
  PGPASSWORD="$DB_PASSWORD" psql -h 127.0.0.1 -p 5433 -U zaptec -d zaptec_prod -c "SELECT 1" &>/dev/null && break || sleep 2
done
log "Banco pronto"

# -------------------------------------------------------------
section "Instalando Dependencias e Compilando"
# -------------------------------------------------------------
# --include=dev: garante tsc/vite no build mesmo se NODE_ENV=production estiver setado
info "Estas etapas são as mais demoradas (podem levar alguns minutos, sem output). Aguarde o spinner."
run_step "Instalando dependências do backend" npm ci --include=dev
cd "$INSTALL_DIR/frontend"
run_step "Instalando dependências do frontend" npm ci --include=dev
run_step "Compilando o frontend (build)" npm run build
cd "$INSTALL_DIR"
run_step "Compilando o backend (build)" npm run build
npm prune --omit=dev --quiet 2>/dev/null || true

# -------------------------------------------------------------
section "Migracoes e Seed do Banco"
# -------------------------------------------------------------
run_step "Gerando cliente Prisma" npx prisma generate
run_step "Aplicando migrações do banco" npx prisma migrate deploy

export ADMIN_EMAIL ADMIN_PASS
ADMIN_EMAIL="$ADMIN_EMAIL" ADMIN_PASS="$ADMIN_PASS" npx tsx prisma/seed.ts && log "Seed executado"
npx tsx prisma/seed-help.ts 2>/dev/null && log "Central de Ajuda populada" || warn "Seed de ajuda ignorado"

# -------------------------------------------------------------
section "Configurando Evolution API"
# -------------------------------------------------------------
# Setup idempotente: segredos, versão do WhatsApp Web, build da 2.4.0-rc2,
# sobe o stack e aponta o ZapTec para a Evolution. Não aborta a instalação.
if [[ -f "$INSTALL_DIR/deploy/evolution/setup-evolution.sh" ]]; then
  INSTALL_DIR="$INSTALL_DIR" bash "$INSTALL_DIR/deploy/evolution/setup-evolution.sh" || warn "Setup da Evolution retornou aviso (não crítico)"
else
  warn "Script da Evolution não encontrado no repo — pulando."
fi

# -------------------------------------------------------------
section "Configurando PM2"
# -------------------------------------------------------------
mkdir -p /var/log/zaptec
cat > "$INSTALL_DIR/ecosystem.config.js" <<PM2EOF
module.exports = {
  apps: [{
    name: 'zaptec-backend',
    script: './dist/server.js',
    cwd: '/opt/zaptec',
    autorestart: true,
    max_memory_restart: '2G',
    error_file: '/var/log/zaptec/error.log',
    out_file: '/var/log/zaptec/out.log',
    log_date_format: 'YYYY-MM-DD HH:mm:ss'
  }]
};
PM2EOF

pm2 start "$INSTALL_DIR/ecosystem.config.js"
pm2 save
env PATH=$PATH:/usr/bin pm2 startup systemd -u root --hp /root 2>/dev/null | grep "^sudo\|^env" | bash || true
log "PM2 na porta ${APP_PORT}"

# -------------------------------------------------------------
section "Proxy / SSL"
# -------------------------------------------------------------
if [[ "$CERTBOT_ENABLED" == true ]]; then
  systemctl enable nginx --now 2>/dev/null || true

  if [[ "$OS_FAMILY" == "debian" ]]; then
    NGINX_CONF="/etc/nginx/sites-available/zaptec"
  else
    NGINX_CONF="/etc/nginx/conf.d/zaptec.conf"
    rm -f /etc/nginx/conf.d/default.conf
    setsebool -P httpd_can_network_connect 1 2>/dev/null || true
  fi

  cat > "$NGINX_CONF" <<NGINXEOF
server {
    listen 80;
    server_name ${APP_DOMAIN};
    root ${INSTALL_DIR}/frontend/dist;
    index index.html;
    location /.well-known/acme-challenge/ { root /var/lib/letsencrypt; }
    location / { try_files \$uri \$uri/ /index.html; }
}
NGINXEOF

  if [[ "$OS_FAMILY" == "debian" ]]; then
    ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/zaptec
    rm -f /etc/nginx/sites-enabled/default
  fi
  nginx -t && systemctl reload nginx

  certbot certonly --nginx -d "$APP_DOMAIN" --email "$LE_EMAIL" --agree-tos --non-interactive
  log "Certificado SSL emitido"

  write_nginx_config "$NGINX_CONF" "$APP_DOMAIN" "$APP_PORT" "true"
  nginx -t && systemctl reload nginx
  (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet && systemctl reload nginx") | sort -u | crontab -
  log "Nginx HTTPS → 127.0.0.1:${APP_PORT}"
else
  info "Certbot desativado — configure seu proxy reverso para ${PUBLIC_URL} → 127.0.0.1:${APP_PORT}"
  info "Rotas necessarias: /api/ /socket.io/ /media/ /uploads/ /webhooks/ e frontend /"
fi

# -------------------------------------------------------------
section "Firewall"
# -------------------------------------------------------------
if [[ "$OS_FAMILY" == "debian" ]]; then
  ufw --force enable
  ufw allow ssh
  if [[ "$CERTBOT_ENABLED" == true ]]; then
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw deny "${APP_PORT}"/tcp
  else
    ufw allow "${APP_PORT}"/tcp
  fi
  ufw deny 5433/tcp
  ufw deny 6379/tcp
  ufw reload
  log "UFW configurado"
else
  systemctl enable firewalld --now
  firewall-cmd --permanent --add-service=ssh
  if [[ "$CERTBOT_ENABLED" == true ]]; then
    firewall-cmd --permanent --add-service=http
    firewall-cmd --permanent --add-service=https
    firewall-cmd --permanent --remove-port="${APP_PORT}"/tcp 2>/dev/null || true
  else
    firewall-cmd --permanent --add-port="${APP_PORT}"/tcp
  fi
  firewall-cmd --permanent --remove-port=5433/tcp 2>/dev/null || true
  firewall-cmd --permanent --remove-port=6379/tcp 2>/dev/null || true
  firewall-cmd --reload
  log "Firewalld configurado"
fi

# -------------------------------------------------------------
section "Fail2ban e Backup"
# -------------------------------------------------------------
cat > /etc/fail2ban/jail.d/zaptec.conf <<'F2BEOF'
[sshd]
enabled = true
maxretry = 5
bantime = 3600
[nginx-http-auth]
enabled = true
F2BEOF
systemctl enable fail2ban --now && log "Fail2ban ativado"

mkdir -p /opt/zaptec-backups
# Instala os scripts de backup e restauração a partir do repositório (fonte única —
# sem fallback inline: se faltar, o clone está incompleto/corrompido e é melhor
# falhar aqui do que instalar silenciosamente um backup incompleto sem mídia).
if [[ ! -f "$INSTALL_DIR/deploy/zaptec-backup.sh" || ! -f "$INSTALL_DIR/deploy/zaptec-restore.sh" ]]; then
  error "deploy/zaptec-backup.sh ou deploy/zaptec-restore.sh não encontrados no clone em $INSTALL_DIR. Repositório incompleto/corrompido."
fi
install -m 755 "$INSTALL_DIR/deploy/zaptec-backup.sh"  /usr/local/bin/zaptec-backup
install -m 755 "$INSTALL_DIR/deploy/zaptec-restore.sh" /usr/local/bin/zaptec-restore
log "Comandos 'zaptec-backup' e 'zaptec-restore' instalados"
(crontab -l 2>/dev/null; echo "0 2 * * * /usr/local/bin/zaptec-backup --with-media >> /var/log/zaptec/backup.log 2>&1") | sort -u | crontab -
log "Backup diario (banco + midias) as 02:00"

# -------------------------------------------------------------
cat > /root/zaptec-credentials.txt <<CREDSEOF
ZapTec SaaS - Credenciais (instalado em $(date '+%d/%m/%Y %H:%M'))
================================================================
URL:         ${PUBLIC_URL}
Porta app:   ${APP_PORT}
Certbot:     $([ "$CERTBOT_ENABLED" == true ] && echo sim || echo nao — use proxy reverso)
Proxy doc:   $([ "$CERTBOT_ENABLED" != true ] && echo "${INSTALL_DIR}/docs/proxy-reverso.md" || echo "n/a")
Login:       ${ADMIN_EMAIL}
Senha:       ${ADMIN_PASS}

Banco:       postgresql://zaptec:${DB_PASSWORD}@127.0.0.1:5433/zaptec_prod
Ticketz:     $([ "$HAS_TICKETZ" == true ] && echo "detectado — aba Migração no painel" || echo "nao detectado")
$([ -n "${TICKETZ_PROXY_URL:-}" ] && echo "Proxy migração: ${TICKETZ_PROXY_URL}")

ATUALIZAR:
  curl -sSL https://raw.githubusercontent.com/${GITHUB_USER}/zaptec-install/main/update.sh | sudo bash

Logs:    pm2 logs zaptec-backend
Status:  pm2 status
================================================================
CREDSEOF
chmod 600 /root/zaptec-credentials.txt

echo ""
echo -e "${GREEN}${BOLD}"
echo "  +--------------------------------------------------+"
echo "  |           Instalacao concluida!                  |"
echo "  +--------------------------------------------------+"
echo -e "${NC}"
echo -e "  ${BOLD}URL:${NC}     ${PUBLIC_URL}"
echo -e "  ${BOLD}Porta:${NC}   ${APP_PORT}"
echo -e "  ${BOLD}Login:${NC}   ${ADMIN_EMAIL}"
echo -e "  ${BOLD}Senha:${NC}   ${ADMIN_PASS}"
if [[ "$HAS_TICKETZ" == true && -n "${TICKETZ_PROXY_URL:-}" ]]; then
  echo -e "  ${BOLD}Migracao:${NC} Ticketz detectado — use o menu SUPER_ADMIN → Migração"
elif [[ "$HAS_TICKETZ" == true ]]; then
  echo -e "  ${YELLOW}Migracao:${NC} Ticketz detectado mas proxy nao iniciou — veja deploy/MIGRATION-TICKETZ.md"
fi
if [[ "$CERTBOT_ENABLED" != true ]]; then
  echo ""
  echo -e "  ${YELLOW}Proxy reverso:${NC} aponte ${PUBLIC_URL} → 127.0.0.1:${APP_PORT}"
  echo -e "  ${YELLOW}Exemplos:${NC}     ${INSTALL_DIR}/docs/proxy-reverso.md"
  echo -e "                 Central de Ajuda → Instalação e Proxy Reverso"
fi
echo ""
echo -e "  ${CYAN}Atualizar:${NC} curl -sSL https://raw.githubusercontent.com/${GITHUB_USER}/zaptec-install/main/update.sh | sudo bash"
echo -e "${YELLOW}  Credenciais: /root/zaptec-credentials.txt${NC}"
echo ""
