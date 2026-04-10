#!/bin/bash
# =============================================================
# ZapTec SaaS - Instalador Automático para VPS
# Compatível com: Ubuntu 22.04+ / Debian 12+
#
# Este script fica no repo PUBLICO: morrice22/zaptec-install
# O repo PRIVADO (morrice22/whatsapp-saas) é clonado com token.
#
# INSTALAR (uma linha):
#   curl -sSL https://raw.githubusercontent.com/morrice22/zaptec-install/main/install.sh | sudo bash
#
# INSTALAR silencioso (sem perguntas interativas):
#   APP_DOMAIN=app.meusite.com LE_EMAIL=eu@mail.com GITHUB_TOKEN=ghp_xxx \
#   curl -sSL https://raw.githubusercontent.com/morrice22/zaptec-install/main/install.sh | sudo bash
#
# ATUALIZAR (sem perda de dados):
#   curl -sSL https://raw.githubusercontent.com/morrice22/zaptec-install/main/update.sh | sudo bash
# =============================================================

set -euo pipefail

# ─── EDITE ANTES DE SUBIR PARA O GITHUB ──────────────────────
GITHUB_USER="morrice22"
GITHUB_REPO="whatsapp-saas"
GITHUB_BRANCH="main"
# ─────────────────────────────────────────────────────────────

INSTALL_DIR="/opt/zaptec"
REPO_URL="https://github.com/${GITHUB_USER}/${GITHUB_REPO}.git"

# ─── Cores ───────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${GREEN}[+]${NC} $1"; }
info()    { echo -e "${BLUE}[i]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[x]${NC} $1"; exit 1; }
section() { echo -e "\n${BOLD}${CYAN}==> $1${NC}"; }

# Lê input mesmo quando stdin é pipe (curl | bash)
ask() {
  local var="$1" prompt="$2" default="${3:-}"
  # Se já definido via variável de ambiente, usa direto
  if [[ -n "${!var:-}" ]]; then return; fi
  printf "%b" "${BOLD}${prompt}${NC}" >/dev/tty
  read -r "$var" </dev/tty
  if [[ -z "${!var:-}" && -n "$default" ]]; then
    printf -v "$var" '%s' "$default"
  fi
}

echo -e "\n${BOLD}${CYAN}"
echo "  +--------------------------------------------------+"
echo "  |       ZapTec SaaS - Instalador VPS v1.0         |"
echo "  +--------------------------------------------------+"
echo -e "${NC}"

# ─────────────────────────────────────────────────────────────
section "Verificacoes"
# ─────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Execute como root: curl ... | sudo bash"
[[ $(uname -m) != "x86_64" ]] && error "Apenas x86_64 suportado."
OS=$(. /etc/os-release && echo "$ID")
[[ "$OS" != "ubuntu" && "$OS" != "debian" ]] && warn "Sistema nao testado: $OS"
log "Sistema: $OS $(. /etc/os-release && echo $VERSION_ID)"

# ─────────────────────────────────────────────────────────────
section "Configuracao"
# ─────────────────────────────────────────────────────────────
ask APP_DOMAIN "Dominio (ex: app.meusite.com.br): "
ask LE_EMAIL   "E-mail para SSL Let's Encrypt: "
ask APP_NAME   "Nome da aplicacao [ZapTec]: " "ZapTec"

# Repo privado: token obrigatorio para clonar
if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  printf "%b" "${BOLD}GitHub Personal Access Token (repo privado — obrigatorio): ${NC}" >/dev/tty
  read -r GITHUB_TOKEN </dev/tty || GITHUB_TOKEN=""
fi
[[ -z "${GITHUB_TOKEN:-}" ]] && error "GITHUB_TOKEN obrigatorio. Gere em: github.com/settings/tokens (scope: Contents read)"

[[ -z "${APP_DOMAIN:-}" ]] && error "Dominio obrigatorio."
[[ -z "${LE_EMAIL:-}" ]]   && error "E-mail obrigatorio."

DB_PASSWORD=$(openssl rand -base64 32 | tr -d '/+=\n' | head -c 32)
JWT_SECRET=$(openssl rand -base64 48 | tr -d '/+=\n' | head -c 48)
JWT_REFRESH=$(openssl rand -base64 48 | tr -d '/+=\n' | head -c 48)
ADMIN_PASS=$(openssl rand -base64 12 | tr -d '/+=\n' | head -c 12)
ADMIN_EMAIL="admin@${APP_DOMAIN}"

info "Dominio:     $APP_DOMAIN"
info "Admin:       $ADMIN_EMAIL"
info "Repo:        $REPO_URL"

# ─────────────────────────────────────────────────────────────
section "Atualizando Sistema"
# ─────────────────────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq curl wget git openssl ca-certificates gnupg lsb-release ufw fail2ban postgresql-client nginx certbot python3-certbot-nginx
log "Sistema atualizado"

# ─────────────────────────────────────────────────────────────
section "Instalando Docker"
# ─────────────────────────────────────────────────────────────
if command -v docker &>/dev/null; then
  log "Docker ja instalado: $(docker --version)"
else
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/$OS/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$OS $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable docker --now
  log "Docker instalado: $(docker --version)"
fi

# ─────────────────────────────────────────────────────────────
section "Instalando Node.js 20 LTS e PM2"
# ─────────────────────────────────────────────────────────────
NODE_VER=0; command -v node &>/dev/null && NODE_VER=$(node -v | cut -d. -f1 | tr -d 'v')
if [[ $NODE_VER -lt 20 ]]; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null 2>&1
  apt-get install -y -qq nodejs
fi
log "Node.js: $(node -v)"
npm install -g pm2 --quiet && log "PM2: $(pm2 --version)"

# ─────────────────────────────────────────────────────────────
section "Clonando Repositorio"
# ─────────────────────────────────────────────────────────────
[[ -d "$INSTALL_DIR" ]] && mv "$INSTALL_DIR" "${INSTALL_DIR}_bkp_$(date +%Y%m%d%H%M%S)"

if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  CLONE_URL="https://${GITHUB_TOKEN}@github.com/${GITHUB_USER}/${GITHUB_REPO}.git"
else
  CLONE_URL="$REPO_URL"
fi
git clone --depth 1 --branch "$GITHUB_BRANCH" "$CLONE_URL" "$INSTALL_DIR"
log "Repositorio clonado em $INSTALL_DIR"
cd "$INSTALL_DIR"

# ─────────────────────────────────────────────────────────────
section "Criando .env (segredos ficam so na VPS)"
# ─────────────────────────────────────────────────────────────
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
ENVEOF
chmod 600 "$INSTALL_DIR/.env"
log ".env criado com permissao 600 (apenas root le)"

# ─────────────────────────────────────────────────────────────
section "Iniciando PostgreSQL e Redis"
# ─────────────────────────────────────────────────────────────
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
      interval: 10s; timeout: 5s; retries: 10
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

info "Aguardando banco..."
for i in {1..30}; do
  PGPASSWORD="$DB_PASSWORD" psql -h 127.0.0.1 -p 5433 -U zaptec -d zaptec_prod -c "SELECT 1" &>/dev/null && break || sleep 2
done
log "Banco pronto"

# ─────────────────────────────────────────────────────────────
section "Instalando Dependencias e Compilando"
# ─────────────────────────────────────────────────────────────
npm ci --omit=dev --quiet && log "Backend: dependencias instaladas"

cd "$INSTALL_DIR/frontend"
npm ci --quiet
npm run build
log "Frontend compilado"

cd "$INSTALL_DIR"
npm run build && log "Backend compilado"

# ─────────────────────────────────────────────────────────────
section "Migracoes e Seed do Banco"
# ─────────────────────────────────────────────────────────────
npx prisma generate
npx prisma migrate deploy
log "Migracoes aplicadas"

npx tsx prisma/seed.ts && log "Seed executado"

# Atualiza email/senha do admin gerados
HASHED=$(node -e "const b=require('bcryptjs');console.log(b.hashSync('${ADMIN_PASS}',10))")
PGPASSWORD="$DB_PASSWORD" psql -h 127.0.0.1 -p 5433 -U zaptec -d zaptec_prod \
  -c "UPDATE users SET email='${ADMIN_EMAIL}', password='${HASHED}' WHERE role='SUPER_ADMIN' LIMIT 1;" 2>/dev/null || true
log "Admin configurado: $ADMIN_EMAIL"

# ─────────────────────────────────────────────────────────────
section "Configurando PM2"
# ─────────────────────────────────────────────────────────────
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

# ─────────────────────────────────────────────────────────────
section "Configurando Nginx"
# ─────────────────────────────────────────────────────────────
cat > /etc/nginx/sites-available/zaptec <<NGINXEOF
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

ln -sf /etc/nginx/sites-available/zaptec /etc/nginx/sites-enabled/zaptec
rm -f /etc/nginx/sites-enabled/default
nginx -t

certbot --nginx -d "$APP_DOMAIN" --email "$LE_EMAIL" --agree-tos --non-interactive --redirect
log "SSL/HTTPS configurado via Let's Encrypt"

(crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet && systemctl reload nginx") | sort -u | crontab -

# ─────────────────────────────────────────────────────────────
section "Firewall (UFW)"
# ─────────────────────────────────────────────────────────────
ufw --force enable
ufw allow ssh
ufw allow 80/tcp
ufw allow 443/tcp
ufw deny 3000/tcp
ufw deny 5433/tcp
ufw deny 6379/tcp
ufw reload
log "UFW: 80/443 abertos, 3000/5433/6379 bloqueados"

# ─────────────────────────────────────────────────────────────
section "Fail2ban"
# ─────────────────────────────────────────────────────────────
cat > /etc/fail2ban/jail.d/zaptec.conf <<'F2BEOF'
[sshd]
enabled = true
maxretry = 5
bantime = 3600
[nginx-http-auth]
enabled = true
F2BEOF
systemctl restart fail2ban && log "Fail2ban ativado"

# ─────────────────────────────────────────────────────────────
section "Backup Automatico Diario"
# ─────────────────────────────────────────────────────────────
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
log "Backup diario as 02:00 (retém 7 dias)"

# ─────────────────────────────────────────────────────────────
# Salvar credenciais
# ─────────────────────────────────────────────────────────────
cat > /root/zaptec-credentials.txt <<CREDSEOF
ZapTec SaaS - Credenciais (instalado em $(date '+%d/%m/%Y %H:%M'))
================================================================
URL:        https://${APP_DOMAIN}
Login:      ${ADMIN_EMAIL}
Senha:      ${ADMIN_PASS}

Banco:      postgresql://zaptec:${DB_PASSWORD}@127.0.0.1:5433/zaptec_prod

ATUALIZAR:
  curl -sSL https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/main/update.sh | sudo bash

Logs:    pm2 logs zaptec-backend
Status:  pm2 status
Backup:  zaptec-backup
================================================================
CREDSEOF
chmod 600 /root/zaptec-credentials.txt

# ─────────────────────────────────────────────────────────────
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
echo -e "  ${CYAN}curl -sSL https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/main/update.sh | sudo bash${NC}"
echo ""
echo -e "${YELLOW}  Credenciais salvas em /root/zaptec-credentials.txt${NC}"
echo ""

