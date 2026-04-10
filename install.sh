#!/bin/bash
# =============================================================
# ZapTec SaaS - Instalador Automatico para VPS
# Compativel com: Ubuntu 22.04+, Debian 12+, AlmaLinux 8+, Rocky Linux 8+
#
# Este script fica no repo PUBLICO: morrice22/zaptec-install
# O repo PRIVADO (morrice22/whatsapp-saas) eh clonado com token.
#
# INSTALAR (uma linha):
#   curl -sSL https://raw.githubusercontent.com/morrice22/zaptec-install/main/install.sh | sudo bash
#
# INSTALAR silencioso:
#   APP_DOMAIN=app.meusite.com LE_EMAIL=eu@mail.com \
#   ADMIN_EMAIL=admin@meusite.com ADMIN_PASS=SenhaForte123 \
#   GITHUB_TOKEN=ghp_xxx \
#   curl -sSL https://raw.githubusercontent.com/morrice22/zaptec-install/main/install.sh | sudo bash
#
# ATUALIZAR (sem perda de dados):
#   curl -sSL https://raw.githubusercontent.com/morrice22/zaptec-install/main/update.sh | sudo bash
# =============================================================

set -euo pipefail

# --- EDITE ANTES DE SUBIR PARA O GITHUB ----------------------
GITHUB_USER="morrice22"
GITHUB_REPO="whatsapp-saas"
GITHUB_BRANCH="main"
# -------------------------------------------------------------

INSTALL_DIR="/opt/zaptec"
REPO_URL="https://github.com/${GITHUB_USER}/${GITHUB_REPO}.git"

# --- Cores ---------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${GREEN}[+]${NC} $1"; }
info()    { echo -e "${BLUE}[i]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[x]${NC} $1"; exit 1; }
section() { echo -e "\n${BOLD}${CYAN}==> $1${NC}"; }

# Le input mesmo quando stdin e pipe (curl | bash)
ask() {
  local var="$1" prompt="$2" default="${3:-}"
  if [[ -n "${!var:-}" ]]; then return; fi
  printf "%b" "${BOLD}${prompt}${NC}" >/dev/tty
  read -r "$var" </dev/tty
  if [[ -z "${!var:-}" && -n "$default" ]]; then
    printf -v "$var" "%s" "$default"
  fi
}

ask_secret() {
  local var="$1" prompt="$2"
  if [[ -n "${!var:-}" ]]; then return; fi
  printf "%b" "${BOLD}${prompt}${NC}" >/dev/tty
  read -rs "$var" </dev/tty
  echo >/dev/tty
}

echo -e "\n${BOLD}${CYAN}"
echo "  +--------------------------------------------------+"
echo "  |       ZapTec SaaS - Instalador VPS v2.0         |"
echo "  +--------------------------------------------------+"
echo -e "${NC}"

# -------------------------------------------------------------
section "Verificacoes"
# -------------------------------------------------------------
[[ $EUID -ne 0 ]] && error "Execute como root: curl ... | sudo bash"
[[ $(uname -m) != "x86_64" ]] && error "Apenas x86_64 suportado."

. /etc/os-release
OS_ID="$ID"
OS_VER="${VERSION_ID%%.*}"

if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then
  OS_FAMILY="debian"
elif [[ "$OS_ID" == "almalinux" || "$OS_ID" == "rhel" || "$OS_ID" == "centos" || "$OS_ID" == "rocky" ]]; then
  OS_FAMILY="rhel"
else
  error "Sistema nao suportado: $OS_ID. Use: Ubuntu, Debian, AlmaLinux, Rocky Linux ou RHEL."
fi

log "Sistema detectado: $OS_ID $VERSION_ID ($OS_FAMILY)"

# -------------------------------------------------------------
section "Configuracao"
# -------------------------------------------------------------
ask APP_DOMAIN  "Dominio (ex: app.meusite.com.br): "
ask LE_EMAIL    "E-mail para SSL Lets Encrypt: "
ask APP_NAME    "Nome da aplicacao [ZapTec]: " "ZapTec"
ask ADMIN_EMAIL "E-mail do administrador master: "
ask_secret ADMIN_PASS "Senha do administrador master (min. 8 caracteres): "

# Repo privado: token obrigatorio para clonar
if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  printf "%b" "${BOLD}GitHub Personal Access Token (repo privado): ${NC}" >/dev/tty
  read -rs GITHUB_TOKEN </dev/tty || GITHUB_TOKEN=""
  echo >/dev/tty
fi

[[ -z "${APP_DOMAIN:-}" ]]   && error "Dominio obrigatorio."
[[ -z "${LE_EMAIL:-}" ]]     && error "E-mail para SSL obrigatorio."
[[ -z "${ADMIN_EMAIL:-}" ]]  && error "E-mail do admin obrigatorio."
[[ -z "${ADMIN_PASS:-}" ]]   && error "Senha do admin obrigatoria."
[[ -z "${GITHUB_TOKEN:-}" ]] && error "GITHUB_TOKEN obrigatorio. Gere em: github.com/settings/tokens (scope: repo)"
[[ ${#ADMIN_PASS} -lt 8 ]]   && error "Senha do admin deve ter no minimo 8 caracteres."

DB_PASSWORD=$(openssl rand -base64 32 | tr -d '/+=\n' | head -c 32)
JWT_SECRET=$(openssl rand -base64 48 | tr -d '/+=\n' | head -c 48)
JWT_REFRESH=$(openssl rand -base64 48 | tr -d '/+=\n' | head -c 48)

info "Dominio:     $APP_DOMAIN"
info "Admin:       $ADMIN_EMAIL"
info "Sistema:     $OS_ID $VERSION_ID"
info "Repo:        $REPO_URL"

# -------------------------------------------------------------
section "Atualizando Sistema e Instalando Dependencias"
# -------------------------------------------------------------
if [[ "$OS_FAMILY" == "debian" ]]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get upgrade -y -qq
  apt-get install -y -qq curl wget git openssl ca-certificates gnupg lsb-release \
    ufw fail2ban postgresql-client nginx certbot python3-certbot-nginx
else
  # Importa a chave GPG do AlmaLinux/RHEL antes de atualizar (evita erro de GPG)
  rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-AlmaLinux 2>/dev/null || \
  rpm --import https://repo.almalinux.org/almalinux/RPM-GPG-KEY-AlmaLinux 2>/dev/null || true
  dnf upgrade -y -q --nogpgcheck 2>/dev/null || dnf upgrade -y -q || true
  dnf install -y -q epel-release
  dnf install -y -q curl wget git openssl ca-certificates gnupg2 \
    firewalld fail2ban postgresql nginx certbot python3-certbot-nginx
fi
log "Sistema atualizado"

# -------------------------------------------------------------
section "Instalando Docker"
# -------------------------------------------------------------
if command -v docker &>/dev/null; then
  log "Docker ja instalado: $(docker --version)"
else
  if [[ "$OS_FAMILY" == "debian" ]]; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/$OS_ID/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$OS_ID $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  else
    dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    dnf install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
  systemctl enable docker --now
  log "Docker instalado: $(docker --version)"
fi

# -------------------------------------------------------------
section "Instalando Node.js 20 LTS e PM2"
# -------------------------------------------------------------
NODE_VER=0; command -v node &>/dev/null && NODE_VER=$(node -v | cut -d. -f1 | tr -d 'v')
if [[ $NODE_VER -lt 20 ]]; then
  if [[ "$OS_FAMILY" == "debian" ]]; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null 2>&1
    apt-get install -y -qq nodejs
  else
    curl -fsSL https://rpm.nodesource.com/setup_20.x | bash - >/dev/null 2>&1
    dnf install -y -q nodejs
  fi
fi
log "Node.js: $(node -v)"
npm install -g pm2 --quiet && log "PM2: $(pm2 --version)"

# -------------------------------------------------------------
section "Clonando Repositorio"
# -------------------------------------------------------------
[[ -d "$INSTALL_DIR" ]] && mv "$INSTALL_DIR" "${INSTALL_DIR}_bkp_$(date +%Y%m%d%H%M%S)"

CLONE_URL="https://${GITHUB_TOKEN}@github.com/${GITHUB_USER}/${GITHUB_REPO}.git"
git clone --depth 1 --branch "$GITHUB_BRANCH" "$CLONE_URL" "$INSTALL_DIR"
log "Repositorio clonado em $INSTALL_DIR"
cd "$INSTALL_DIR"

# -------------------------------------------------------------
section "Criando .env (segredos ficam so na VPS)"
# -------------------------------------------------------------
cat > "$INSTALL_DIR/.env" <<ENVEOF
# ZapTec SaaS - Gerado em $(date '+%d/%m/%Y %H:%M') - NAO SUBA PARA O GITHUB!
NODE_ENV=production
PORT=3000
API_URL=https://${APP_DOMAIN}
BACKEND_URL=https://${APP_DOMAIN}
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
CORS_ORIGIN=https://${APP_DOMAIN}
DEFAULT_MAX_CONNECTIONS=3
DEFAULT_MAX_USERS=5

# Backup Google Drive (opcional — configure em: console.cloud.google.com/apis/credentials)
GOOGLE_CLIENT_ID=
GOOGLE_CLIENT_SECRET=
GOOGLE_REDIRECT_URI=https://${APP_DOMAIN}/api/backup/google/callback
ENVEOF
chmod 600 "$INSTALL_DIR/.env"
log ".env criado com permissao 600 (apenas root le)"

# -------------------------------------------------------------
section "Iniciando PostgreSQL e Redis"
# -------------------------------------------------------------
# Para e remove containers anteriores para evitar conflito de senha no volume
docker stop zaptec-db zaptec-redis 2>/dev/null || true
docker rm   zaptec-db zaptec-redis 2>/dev/null || true
# Remove dados antigos do Postgres para garantir inicializacao limpa com nova senha
rm -rf /opt/zaptec-data/postgres
mkdir -p /opt/zaptec-data/postgres /opt/zaptec-data/redis

cat > "$INSTALL_DIR/docker-compose.prod.yml" <<DCEOF
services:
  postgres:
    image: postgres:16-alpine
    container_name: zaptec-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: zaptec_prod
      POSTGRES_USER: zaptec
      POSTGRES_PASSWORD: "${DB_PASSWORD}"
    ports:
      - "127.0.0.1:5433:5432"
    volumes:
      - /opt/zaptec-data/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U zaptec -d zaptec_prod"]
      interval: 10s
      timeout: 5s
      retries: 10
  redis:
    image: redis:7-alpine
    container_name: zaptec-redis
    restart: unless-stopped
    command: redis-server --save 60 1 --loglevel warning
    ports:
      - "127.0.0.1:6379:6379"
    volumes:
      - /opt/zaptec-data/redis:/data
DCEOF

docker compose -f "$INSTALL_DIR/docker-compose.prod.yml" up -d
log "Containers iniciados"

info "Aguardando banco ficar pronto..."
for i in {1..30}; do
  PGPASSWORD="$DB_PASSWORD" psql -h 127.0.0.1 -p 5433 -U zaptec -d zaptec_prod -c "SELECT 1" &>/dev/null && break || sleep 2
done
log "Banco pronto"

# -------------------------------------------------------------
section "Instalando Dependencias e Compilando"
# -------------------------------------------------------------
npm ci --quiet && log "Backend: dependencias instaladas"

cd "$INSTALL_DIR/frontend"
npm ci --quiet
npm run build
log "Frontend compilado"

cd "$INSTALL_DIR"
npm run build
log "Backend compilado"
# Remove dependencias de dev apos build (economiza disco)
npm prune --omit=dev --quiet 2>/dev/null || true

# -------------------------------------------------------------
section "Migracoes e Seed do Banco"
# -------------------------------------------------------------
npx prisma generate
npx prisma migrate deploy
log "Migracoes aplicadas"

# Exporta credenciais para que o seed as use diretamente
export ADMIN_EMAIL ADMIN_PASS
ADMIN_EMAIL="$ADMIN_EMAIL" ADMIN_PASS="$ADMIN_PASS" npx tsx prisma/seed.ts && log "Seed executado"
log "Admin master configurado: $ADMIN_EMAIL"

# -------------------------------------------------------------
section "Configurando PM2"
# -------------------------------------------------------------
mkdir -p /var/log/zaptec
cat > "$INSTALL_DIR/ecosystem.config.js" <<'PM2EOF'
module.exports = {
  apps: [{
    name: 'zaptec-backend',
    script: './dist/server.js',
    cwd: '/opt/zaptec',
    autorestart: true,
    max_memory_restart: '1G',
    error_file: '/var/log/zaptec/error.log',
    out_file: '/var/log/zaptec/out.log',
    log_date_format: 'YYYY-MM-DD HH:mm:ss'
  }]
};
PM2EOF

pm2 start "$INSTALL_DIR/ecosystem.config.js"
pm2 save
env PATH=$PATH:/usr/bin pm2 startup systemd -u root --hp /root 2>/dev/null | grep "^sudo\|^env" | bash || true
log "PM2 configurado com auto-start no boot"

# -------------------------------------------------------------
section "Configurando Nginx"
# -------------------------------------------------------------
systemctl enable nginx --now 2>/dev/null || true

if [[ "$OS_FAMILY" == "debian" ]]; then
  NGINX_CONF="/etc/nginx/sites-available/zaptec"
else
  NGINX_CONF="/etc/nginx/conf.d/zaptec.conf"
  rm -f /etc/nginx/conf.d/default.conf
  # SELinux: permite nginx conectar na rede (AlmaLinux/RHEL)
  setsebool -P httpd_can_network_connect 1 2>/dev/null || true
fi

# PASSO 1: Config HTTP simples para que o Certbot consiga validar o dominio
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
log "Nginx HTTP iniciado (aguardando cert SSL)"

# PASSO 2: Emite o certificado SSL
certbot certonly --nginx -d "$APP_DOMAIN" --email "$LE_EMAIL" --agree-tos --non-interactive
log "Certificado SSL emitido para $APP_DOMAIN"

# PASSO 3: Substitui pelo config HTTPS completo
cat > "$NGINX_CONF" <<NGINXEOF
server {
    listen 80;
    server_name ${APP_DOMAIN};
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name ${APP_DOMAIN};
    ssl_certificate     /etc/letsencrypt/live/${APP_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${APP_DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_session_cache shared:SSL:10m;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options SAMEORIGIN;
    add_header X-Content-Type-Options nosniff;
    root ${INSTALL_DIR}/frontend/dist;
    index index.html;
    location /api/ {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        client_max_body_size 50m;
    }
    location /socket.io/ {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 3600s;
    }
    location /media/ {
        proxy_pass http://127.0.0.1:3000;
        client_max_body_size 50m;
    }
    location /webhooks/ {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host \$host;
    }
    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
NGINXEOF

nginx -t && systemctl reload nginx
log "SSL/HTTPS configurado via Lets Encrypt"

(crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet && systemctl reload nginx") | sort -u | crontab -

# -------------------------------------------------------------
section "Firewall"
# -------------------------------------------------------------
if [[ "$OS_FAMILY" == "debian" ]]; then
  ufw --force enable
  ufw allow ssh
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw deny 3000/tcp
  ufw deny 5433/tcp
  ufw deny 6379/tcp
  ufw reload
  log "UFW: 80/443 abertos, 3000/5433/6379 bloqueados"
else
  systemctl enable firewalld --now
  firewall-cmd --permanent --add-service=ssh
  firewall-cmd --permanent --add-service=http
  firewall-cmd --permanent --add-service=https
  firewall-cmd --permanent --remove-port=3000/tcp 2>/dev/null || true
  firewall-cmd --permanent --remove-port=5433/tcp 2>/dev/null || true
  firewall-cmd --permanent --remove-port=6379/tcp 2>/dev/null || true
  firewall-cmd --reload
  log "Firewalld: 80/443 abertos, 3000/5433/6379 bloqueados"
fi

# -------------------------------------------------------------
section "Fail2ban"
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

# -------------------------------------------------------------
section "Backup Automatico Diario"
# -------------------------------------------------------------
mkdir -p /opt/zaptec-backups

cat > /usr/local/bin/zaptec-backup <<'BKEOF'
#!/bin/bash
set -euo pipefail
source /opt/zaptec/.env 2>/dev/null || exit 1
DB_HOST=$(echo "$DATABASE_URL" | sed -E 's|.*@([^:/]+).*|\1|')
DB_PORT=$(echo "$DATABASE_URL" | sed -E 's|.*:([0-9]+)/.*|\1|')
DB_NAME=$(echo "$DATABASE_URL" | sed -E 's|.*/([^?]+).*|\1|')
DB_USER=$(echo "$DATABASE_URL" | sed -E 's|.*://([^:]+):.*|\1|')
DB_PASS=$(echo "$DATABASE_URL" | sed -E 's|.*://[^:]+:([^@]+)@.*|\1|')
DATE=$(date +%Y%m%d_%H%M%S)
PGPASSWORD="$DB_PASS" pg_dump -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" "$DB_NAME" \
  | gzip > "/opt/zaptec-backups/backup_${DATE}.sql.gz"
ls -t /opt/zaptec-backups/*.sql.gz 2>/dev/null | tail -n +8 | xargs -r rm
echo "[$(date '+%Y-%m-%d %H:%M')] OK: backup_${DATE}.sql.gz"
BKEOF

chmod +x /usr/local/bin/zaptec-backup
(crontab -l 2>/dev/null; echo "0 2 * * * /usr/local/bin/zaptec-backup >> /var/log/zaptec/backup.log 2>&1") | sort -u | crontab -
log "Backup diario as 02:00 (reten 7 dias)"

# -------------------------------------------------------------
# Salvar credenciais
# -------------------------------------------------------------
cat > /root/zaptec-credentials.txt <<CREDSEOF
ZapTec SaaS - Credenciais (instalado em $(date '+%d/%m/%Y %H:%M'))
================================================================
URL:         https://${APP_DOMAIN}
Login:       ${ADMIN_EMAIL}
Senha:       ${ADMIN_PASS}

Banco:       postgresql://zaptec:${DB_PASSWORD}@127.0.0.1:5433/zaptec_prod
Sistema:     ${OS_ID} ${VERSION_ID}

ATUALIZAR:
  curl -sSL https://raw.githubusercontent.com/${GITHUB_USER}/zaptec-install/main/update.sh | sudo bash

Logs:    pm2 logs zaptec-backend
Status:  pm2 status
Backup:  zaptec-backup
================================================================
CREDSEOF
chmod 600 /root/zaptec-credentials.txt

# -------------------------------------------------------------
echo ""
echo -e "${GREEN}${BOLD}"
echo "  +--------------------------------------------------+"
echo "  |           Instalacao concluida!                  |"
echo "  +--------------------------------------------------+"
echo -e "${NC}"
echo -e "  ${BOLD}URL:${NC}    https://${APP_DOMAIN}"
echo -e "  ${BOLD}Login:${NC}  ${ADMIN_EMAIL}"
echo -e "  ${BOLD}Senha:${NC}  ${ADMIN_PASS}"
echo ""
echo -e "  ${BOLD}Para atualizar no futuro (sem perda de dados):${NC}"
echo -e "  ${CYAN}curl -sSL https://raw.githubusercontent.com/${GITHUB_USER}/zaptec-install/main/update.sh | sudo bash${NC}"
echo ""
echo -e "${YELLOW}  Credenciais salvas em /root/zaptec-credentials.txt${NC}"
echo ""
