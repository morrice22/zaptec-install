#!/bin/bash
# =============================================================
# ZapTec SaaS - Script de Atualização (SEM PERDA DE DADOS)
#
# Este script fica no repo PUBLICO: morrice22/zaptec-install
#
# COMO USAR na VPS:
#
# Hub central (branch main — padrão):
#   curl -sSL https://raw.githubusercontent.com/morrice22/zaptec-install/main/update.sh | sudo bash
#
# VM cliente (branch clientes — consome ZapTec Hub):
#   VERSION=clientes curl -sSL https://raw.githubusercontent.com/morrice22/zaptec-install/main/update.sh | sudo bash
#
# Tag ou branch específica:
#   VERSION=v2.1.0 curl -sSL .../update.sh | sudo bash
# =============================================================

set -euo pipefail

# ─── Configuração ────────────────────────────────────────────
GITHUB_USER="morrice22"
GITHUB_REPO="whatsapp-saas"
GITHUB_BRANCH="${VERSION:-main}"
INSTALL_DIR="/opt/zaptec"

# ─── Cores ───────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${GREEN}[✓]${NC} $1"; }
info()    { echo -e "${BLUE}[i]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[✗]${NC} $1"; exit 1; }
section() { echo -e "\n${BOLD}${CYAN}══ $1 ══${NC}"; }

# Garante variável KEY=VALUE no arquivo (cria ou substitui linha existente).
set_env_var() {
  local key="$1" value="$2" file="$3"
  if grep -q "^${key}=" "$file" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    echo "${key}=${value}" >> "$file"
  fi
}

# Branch clientes → VM filha (credenciais Hub, sem signup Meta local).
configure_clientes_profile() {
  section "Perfil: VM Cliente (branch clientes)"
  set_env_var "ZAPTEC_CLIENTES_MODE" "true" "$INSTALL_DIR/.env"
  set_env_var "VITE_ZAPTEC_CLIENTES_MODE" "true" "$INSTALL_DIR/frontend/.env"
  log "ZAPTEC_CLIENTES_MODE=true (.env)"
  log "VITE_ZAPTEC_CLIENTES_MODE=true (frontend/.env)"
  info "Conexões Cloud API/Instagram: use URL + API Key do Hub central"
}

# Branch main → Hub central (Meta direto, API Externa para VMs filhas).
configure_hub_profile() {
  section "Perfil: Hub Central (branch main)"
  if grep -q "^ZAPTEC_CLIENTES_MODE=" "$INSTALL_DIR/.env" 2>/dev/null; then
    set_env_var "ZAPTEC_CLIENTES_MODE" "false" "$INSTALL_DIR/.env"
    log "ZAPTEC_CLIENTES_MODE=false (.env)"
  fi
  if [[ -f "$INSTALL_DIR/frontend/.env" ]] && grep -q "^VITE_ZAPTEC_CLIENTES_MODE=" "$INSTALL_DIR/frontend/.env"; then
    set_env_var "VITE_ZAPTEC_CLIENTES_MODE" "false" "$INSTALL_DIR/frontend/.env"
    log "VITE_ZAPTEC_CLIENTES_MODE=false (frontend/.env)"
  fi
}

configure_install_profile() {
  case "$GITHUB_BRANCH" in
    clientes) configure_clientes_profile ;;
    main)     configure_hub_profile ;;
    *)        info "Branch '$GITHUB_BRANCH': perfil de instalação não alterado" ;;
  esac
}

INSTALL_PROFILE="$([ "$GITHUB_BRANCH" = "clientes" ] && echo "VM Cliente" || ([ "$GITHUB_BRANCH" = "main" ] && echo "Hub Central" || echo "$GITHUB_BRANCH"))"

echo -e "${BOLD}${CYAN}"
echo "  ╔══════════════════════════════════════════════╗"
echo "  ║       ZapTec SaaS - Atualização do Sistema  ║"
echo "  ║       Branch: $GITHUB_BRANCH"
echo "  ║       Perfil:  $INSTALL_PROFILE"
echo "  ╚══════════════════════════════════════════════╝"
echo -e "${NC}"

# ─── Verificações ─────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Execute como root: sudo bash update.sh"
[[ ! -d "$INSTALL_DIR" ]] && error "Instalação não encontrada em $INSTALL_DIR. Use install.sh primeiro."
[[ ! -f "$INSTALL_DIR/.env" ]] && error "Arquivo .env não encontrado. A instalação pode estar incompleta."

# Metadados da instalação (porta, certbot, ticketz)
APP_PORT=3000
USE_CERTBOT=yes
HAS_TICKETZ=no
if [[ -f "$INSTALL_DIR/.install-meta" ]]; then
  # shellcheck disable=SC1090
  source "$INSTALL_DIR/.install-meta" 2>/dev/null || true
fi
APP_PORT="${APP_PORT:-$(grep '^PORT=' "$INSTALL_DIR/.env" 2>/dev/null | cut -d= -f2 | tr -d '\r' || echo 3000)}"
info "Porta backend: $APP_PORT | Certbot na VPS: ${USE_CERTBOT:-yes}"

# ─── Verificar serviços dependentes ────────────────────────────
section "Verificando Serviços"

# Verifica container por nome (independente do arquivo compose usado na instalação)
if docker ps --format '{{.Names}}' | grep -q "zaptec-db"; then
  log "PostgreSQL: rodando"
elif docker compose -f "$INSTALL_DIR/docker-compose.prod.yml" ps 2>/dev/null | grep -q "running\|Up"; then
  log "PostgreSQL: rodando"
else
  # Tenta iniciar o container se ele existir mas estiver parado
  if docker ps -a --format '{{.Names}}' | grep -q "zaptec-db"; then
    warn "PostgreSQL parado, iniciando..."
    if [ -f "$INSTALL_DIR/docker-compose.prod.yml" ]; then
      docker compose -f "$INSTALL_DIR/docker-compose.prod.yml" up -d
    else
      docker compose -f "$INSTALL_DIR/docker-compose.yml" up -d
    fi
    sleep 5
    docker ps --format '{{.Names}}' | grep -q "zaptec-db" || error "PostgreSQL não iniciou. Verifique com: docker ps -a"
    log "PostgreSQL: iniciado"
  else
    error "PostgreSQL não está rodando! Execute: cd $INSTALL_DIR && docker compose up -d"
  fi
fi

if command -v pm2 &>/dev/null; then
  log "PM2: disponível"
else
  warn "PM2 não encontrado, instalando..."
  npm install -g pm2 --quiet
fi

# ─── Salvar backup automático ANTES de atualizar ──────────────
section "Backup de Segurança Pré-Atualização"

BACKUP_DIR="/opt/zaptec-backups"
mkdir -p "$BACKUP_DIR"
DATE=$(date +%Y%m%d_%H%M%S)

# Extrai credenciais do .env atual
DB_URL=$(grep "^DATABASE_URL=" "$INSTALL_DIR/.env" | cut -d= -f2-)
DB_NAME=$(echo "$DB_URL" | sed -E 's|.*/([^?]+).*|\1|')
DB_USER=$(echo "$DB_URL" | sed -E 's|.*://([^:]+):.*|\1|')
DB_PASS=$(echo "$DB_URL" | sed -E 's|.*://[^:]+:([^@]+)@.*|\1|')

BACKUP_FILE="$BACKUP_DIR/pre_update_${DATE}.sql.gz"

# Usa pg_dump de DENTRO do container Docker para evitar incompatibilidade de versão
docker exec zaptec-db \
  sh -c "PGPASSWORD='${DB_PASS}' pg_dump -U '${DB_USER}' '${DB_NAME}'" \
  | gzip > "$BACKUP_FILE"

BACKUP_SIZE=$(du -sh "$BACKUP_FILE" | cut -f1)
log "Backup criado: pre_update_${DATE}.sql.gz ($BACKUP_SIZE)"
info "Localização: $BACKUP_FILE"

# ─── Registrar versão atual ────────────────────────────────────
section "Verificando Versão"

CURRENT_COMMIT="desconhecido"
if [[ -f "$INSTALL_DIR/.git/HEAD" ]]; then
  CURRENT_COMMIT=$(git -C "$INSTALL_DIR" rev-parse --short HEAD 2>/dev/null || echo "desconhecido")
fi
info "Versão atual: $CURRENT_COMMIT"

# ─── Baixar novo código (preservando .env e dados) ─────────────
section "Baixando Atualização"

# Entra no diretório e faz pull seguro
cd "$INSTALL_DIR"

# Stash de qualquer mudança local para não perder o .env e outros
git stash --include-untracked --quiet 2>/dev/null || true

# Atualiza o remote e faz pull
git fetch origin "$GITHUB_BRANCH"
git checkout "$GITHUB_BRANCH"
git pull origin "$GITHUB_BRANCH" --ff-only

NEW_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "desconhecido")
log "Código atualizado: $CURRENT_COMMIT → $NEW_COMMIT"

# Restaura o .env e metadados locais (nunca sobrescrever com pull)
git checkout -- .env .install-meta 2>/dev/null || true

# ─── Proxy Ticketz (se detectado na instalação) ───────────────
if [[ "${HAS_TICKETZ:-no}" == "yes" && -f "$INSTALL_DIR/deploy/ticketz-proxy.js" ]]; then
  if ! docker ps --format '{{.Names}}' | grep -q '^ticketz-mig-proxy$'; then
    warn "Proxy Ticketz parado — tentando reiniciar..."
    if docker ps -a --format '{{.Names}}' | grep -q '^ticketz-mig-proxy$'; then
      docker start ticketz-mig-proxy 2>/dev/null && log "Proxy Ticketz reiniciado" || warn "Não foi possível reiniciar ticketz-mig-proxy"
    fi
  else
    log "Proxy Ticketz: rodando"
  fi
fi

# ─── Atualizar dependências do backend ────────────────────────
section "Atualizando Dependências"

npm ci --quiet
log "Dependências do backend atualizadas"

# ─── Rodar migrations (SEGURO - apenas adiciona, nunca apaga dados) ─
section "Aplicando Migrations do Banco"

# Regenera o Prisma client com o schema atualizado
npx prisma generate

# ── Helper: marca como rolled-back qualquer migration que ficou com falha
# (finished_at IS NULL E rolled_back_at IS NULL) no _prisma_migrations.
# Resolve P3009 (failed migration) e P3018 (apply failed) automaticamente,
# pois o Prisma roda cada migration em transação — se falhar, nada foi
# realmente persistido e podemos seguramente marcar como revertida.
auto_resolve_failed_migrations() {
  local DB_URL_LOCAL DB_NAME_LOCAL DB_USER_LOCAL DB_PASS_LOCAL FAILED_LIST
  DB_URL_LOCAL=$(grep "^DATABASE_URL=" "$INSTALL_DIR/.env" | cut -d= -f2-)
  DB_NAME_LOCAL=$(echo "$DB_URL_LOCAL" | sed -E 's|.*/([^?]+).*|\1|')
  DB_USER_LOCAL=$(echo "$DB_URL_LOCAL" | sed -E 's|.*://([^:]+):.*|\1|')
  DB_PASS_LOCAL=$(echo "$DB_URL_LOCAL" | sed -E 's|.*://[^:]+:([^@]+)@.*|\1|')

  FAILED_LIST=$(docker exec zaptec-db sh -c \
    "PGPASSWORD='${DB_PASS_LOCAL}' psql -U '${DB_USER_LOCAL}' '${DB_NAME_LOCAL}' -tAc \
    \"SELECT migration_name FROM _prisma_migrations WHERE finished_at IS NULL AND rolled_back_at IS NULL;\"" 2>/dev/null \
    | tr -d '\r' | grep -v '^$' || true)

  if [[ -z "$FAILED_LIST" ]]; then
    return 1   # nada a resolver
  fi

  while IFS= read -r MIG; do
    [[ -z "$MIG" ]] && continue
    warn "Migração com falha detectada: $MIG → marcando como rolled-back"
    npx prisma migrate resolve --rolled-back "$MIG" || true
  done <<< "$FAILED_LIST"
  return 0
}

# migrate deploy: aplica apenas migrations novas, NUNCA desfaz dados existentes
# Em caso de drift (ex.: db push anterior + migration parcialmente aplicada),
# tenta recuperar automaticamente com ALTERs idempotentes e resolve de estado.
if npx prisma migrate deploy; then
  log "Migrations aplicadas com segurança (dados preservados)"
else
  warn "Falha ao aplicar migrations; tentando auto-recuperação..."

  # 1ª tentativa: marcar migrações com falha como rolled-back e re-aplicar
  if auto_resolve_failed_migrations; then
    info "Re-aplicando migrations após auto-recuperação..."
    if npx prisma migrate deploy; then
      log "Migrations recuperadas e aplicadas com segurança (dados preservados)"
    else
      warn "Auto-recuperação genérica não resolveu; iniciando rotina manual..."
      RUN_LEGACY_FIX=1
    fi
  else
    RUN_LEGACY_FIX=1
  fi

  # 2ª tentativa (legado): patch idempotente para drifts conhecidos
  if [[ "${RUN_LEGACY_FIX:-0}" == "1" ]]; then
    PRISMA_FIX_SQL="/tmp/zaptec_prisma_fix_$$.sql"
    cat > "$PRISMA_FIX_SQL" <<'SQL'
ALTER TABLE "company_settings"
  ADD COLUMN IF NOT EXISTS "disconnectAlertEnabled" BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS "disconnectAlertPhone" TEXT,
  ADD COLUMN IF NOT EXISTS "disconnectAlertConnectionId" TEXT,
  ADD COLUMN IF NOT EXISTS "disconnectAlertTemplateName" TEXT,
  ADD COLUMN IF NOT EXISTS "disconnectAlertTemplateLang" TEXT DEFAULT 'pt_BR',
  ADD COLUMN IF NOT EXISTS "emailProvider" TEXT NOT NULL DEFAULT 'smtp',
  ADD COLUMN IF NOT EXISTS "resendApiKey" TEXT;

ALTER TABLE "company_settings"
  DROP COLUMN IF EXISTS "disconnectAlertMessage";

-- Índices de performance
CREATE INDEX IF NOT EXISTS "tickets_connectionId_idx" ON "tickets" ("connectionId");
CREATE INDEX IF NOT EXISTS "tickets_userId_idx" ON "tickets" ("userId");
CREATE INDEX IF NOT EXISTS "tickets_queueId_idx" ON "tickets" ("queueId");
CREATE INDEX IF NOT EXISTS "tickets_companyId_lastMessageAt_idx" ON "tickets" ("companyId", "lastMessageAt");
CREATE INDEX IF NOT EXISTS "messages_ticketId_createdAt_idx" ON "messages" ("ticketId", "createdAt");
CREATE INDEX IF NOT EXISTS "messages_connectionId_idx" ON "messages" ("connectionId");
CREATE INDEX IF NOT EXISTS "users_companyId_idx" ON "users" ("companyId");
CREATE INDEX IF NOT EXISTS "whatsapp_connections_companyId_idx" ON "whatsapp_connections" ("companyId");
CREATE INDEX IF NOT EXISTS "contact_tags_tagId_idx" ON "contact_tags" ("tagId");
CREATE INDEX IF NOT EXISTS "ticket_tags_tagId_idx" ON "ticket_tags" ("tagId");
SQL

    npx prisma db execute --schema prisma/schema.prisma --file "$PRISMA_FIX_SQL"
    rm -f "$PRISMA_FIX_SQL"

    npx prisma migrate resolve --rolled-back 20260417135604_add_disconnect_alert_settings || true
    npx prisma migrate resolve --applied 20260417135604_add_disconnect_alert_settings || true
    npx prisma migrate resolve --rolled-back 20260417140451_rename_alert_message_to_template || true
    npx prisma migrate resolve --applied 20260417140451_rename_alert_message_to_template || true
    npx prisma migrate resolve --rolled-back 20260417145842_add_performance_indexes || true
    npx prisma migrate resolve --applied 20260417145842_add_performance_indexes || true

    # Última passada: marca de novo qualquer migration ainda em estado de falha
    auto_resolve_failed_migrations || true

    npx prisma migrate deploy
    log "Migrations recuperadas e aplicadas com segurança (dados preservados)"
  fi
fi

# ─── Seed da Central de Ajuda ──────────────────────────────────
section "Atualizando Central de Ajuda"
npx tsx prisma/seed-help.ts 2>/dev/null && log "Artigos de ajuda atualizados" || warn "Seed de ajuda ignorado (não crítico)"

# ─── Perfil Hub / VM Cliente (antes do build — Vite lê frontend/.env) ──
configure_install_profile

# ─── Build do frontend ─────────────────────────────────────────
section "Compilando Frontend"

cd "$INSTALL_DIR/frontend"
npm ci --quiet
npm run build
log "Frontend compilado"
cd "$INSTALL_DIR"

# ─── Build do backend ──────────────────────────────────────────
section "Compilando Backend"

npm run build
log "Backend compilado"

# ─── Ajustes de estabilidade (idempotentes) ────────────────────
section "Aplicando Ajustes de Estabilidade"

# 1) PM2: subir limite de memória de 1G → 2G (instalações antigas).
#    Com muitos tickets/conexões, 1G estoura e o PM2 fica reiniciando em loop.
if [[ -f "$INSTALL_DIR/ecosystem.config.js" ]] && grep -q "max_memory_restart: '1G'" "$INSTALL_DIR/ecosystem.config.js"; then
  sed -i "s/max_memory_restart: '1G'/max_memory_restart: '2G'/" "$INSTALL_DIR/ecosystem.config.js"
  log "PM2 max_memory_restart ajustado para 2G"
fi

# 2) .env: garantir que o painel admin use 'restart' (não 'reload').
#    reload roda dois processos com a mesma sessão Baileys → WhatsApp derruba a conexão.
if ! grep -q "^PM2_RELOAD_COMMAND=" "$INSTALL_DIR/.env"; then
  echo "PM2_RELOAD_COMMAND=pm2 restart zaptec-backend --update-env" >> "$INSTALL_DIR/.env"
  log "PM2_RELOAD_COMMAND adicionado ao .env (restart, não reload)"
fi

# 3) .env: garantir flag de sync de histórico DESLIGADA por padrão.
#    Quando ligada sem limites, dispara fetchMessageHistory para todos os tickets
#    ao conectar e estoura memória/derruba a sessão (loop de crash/restart).
if ! grep -q "^WHATSAPP_SYNC_HISTORY_ON_CONNECT=" "$INSTALL_DIR/.env"; then
  {
    echo "WHATSAPP_SYNC_HISTORY_ON_CONNECT=false"
    echo "WHATSAPP_SYNC_HISTORY_MAX=20"
    echo "WHATSAPP_SYNC_HISTORY_DELAY_MS=800"
  } >> "$INSTALL_DIR/.env"
  log "Flags WHATSAPP_SYNC_HISTORY_* adicionadas ao .env (sync em massa desligado)"
fi

# 4) .env: intervalo mínimo entre envios (evita rate-overlimit por rajada).
if ! grep -q "^WHATSAPP_MIN_SEND_INTERVAL_MS=" "$INSTALL_DIR/.env"; then
  echo "WHATSAPP_MIN_SEND_INTERVAL_MS=1000" >> "$INSTALL_DIR/.env"
  log "WHATSAPP_MIN_SEND_INTERVAL_MS adicionado ao .env (throttle de envio)"
fi

# ─── Reiniciar aplicação via PM2 ───────────────────────────────
section "Reiniciando Serviço"

if pm2 list | grep -q "zaptec-backend"; then
  # restart (não reload) para evitar que dois processos rodem em paralelo com a mesma sessão Baileys.
  # pm2 reload (zero-downtime) faz o processo novo iniciar antes do antigo parar → conflito de sessão
  # → WhatsApp desconecta a sessão. Com restart, o antigo encerra (graceful shutdown preserva a sessão
  # no disco) antes do novo iniciar → reconecta sem precisar escanear QR novamente.
  # Reiniciar a partir do ecosystem.config.js para reler opções (ex.: max_memory_restart).
  if [[ -f "$INSTALL_DIR/ecosystem.config.js" ]]; then
    pm2 restart "$INSTALL_DIR/ecosystem.config.js" --update-env
  else
    pm2 restart zaptec-backend --update-env
  fi
  pm2 save
  log "Backend reiniciado via PM2 (sessões Baileys preservadas)"
else
  pm2 start ecosystem.config.js
  pm2 save
  log "Backend iniciado via PM2"
fi

# ─── Migração de domínio (opcional) ──────────────────────────
# Para migrar de domínio, defina a variável NEW_DOMAIN antes de executar:
#   NEW_DOMAIN=app.zaptec.online LE_EMAIL=seu@email.com \
#     curl -sSL https://raw.githubusercontent.com/morrice22/zaptec-install/main/update.sh | sudo bash
if [[ -n "${NEW_DOMAIN:-}" ]]; then
  section "Migração de Domínio → $NEW_DOMAIN"

  # Ler domínio atual do .env
  OLD_DOMAIN=$(grep "^BACKEND_URL=" "$INSTALL_DIR/.env" | sed -E 's|^BACKEND_URL=https?://||' | tr -d '\r')
  if [[ -z "$OLD_DOMAIN" ]]; then
    warn "Não foi possível ler BACKEND_URL do .env — pulando migração de domínio"
  elif [[ "$OLD_DOMAIN" == "$NEW_DOMAIN" ]]; then
    info "Domínio já está configurado como $NEW_DOMAIN — nenhuma ação necessária"
  else
    info "Domínio atual: $OLD_DOMAIN → novo: $NEW_DOMAIN"

    NGINX_CONF_NEW=$(find /etc/nginx/sites-available /etc/nginx/conf.d -name "zaptec*.conf" 2>/dev/null | head -1)
    [[ -z "$NGINX_CONF_NEW" ]] && NGINX_CONF_NEW=$(find /etc/nginx/sites-available /etc/nginx/conf.d -name "*.conf" 2>/dev/null | head -1)
    [[ -z "$NGINX_CONF_NEW" ]] && NGINX_CONF_NEW="/etc/nginx/sites-available/zaptec"

    if [[ "${USE_CERTBOT:-yes}" == "yes" ]] && command -v nginx &>/dev/null; then
      # 1) Garantir que certbot está disponível
      if ! command -v certbot &>/dev/null; then
        warn "Certbot não encontrado, instalando..."
        apt-get install -y -qq certbot python3-certbot-nginx 2>/dev/null \
          || dnf install -y -q certbot python3-certbot-nginx 2>/dev/null \
          || error "Não foi possível instalar o certbot. Instale manualmente e execute novamente."
      fi

      # 2) Config HTTP temporária para emitir cert
      NGINX_TMP="/etc/nginx/sites-available/zaptec-newdomain"
      cat > "$NGINX_TMP" <<NGINX_TMP_EOF
server {
    listen 80;
    server_name ${NEW_DOMAIN};
    location /.well-known/acme-challenge/ { root /var/lib/letsencrypt; }
    location / { return 200 'ok'; add_header Content-Type text/plain; }
}
NGINX_TMP_EOF

      if [[ -d /etc/nginx/sites-enabled ]]; then
        ln -sf "$NGINX_TMP" /etc/nginx/sites-enabled/zaptec-newdomain
      fi
      nginx -t && systemctl reload nginx
      log "Nginx temporário HTTP ativo para $NEW_DOMAIN"

      LE_EMAIL_DOMAIN="${LE_EMAIL:-}"
      if [[ -z "$LE_EMAIL_DOMAIN" ]]; then
        LE_EMAIL_DOMAIN=$(certbot show_account 2>/dev/null | grep "Email" | awk '{print $2}' || echo "")
      fi
      [[ -z "$LE_EMAIL_DOMAIN" ]] && error "Defina LE_EMAIL=seu@email.com ao executar o script com NEW_DOMAIN"

      certbot certonly --nginx -d "$NEW_DOMAIN" \
        --email "$LE_EMAIL_DOMAIN" --agree-tos --non-interactive
      log "Certificado SSL emitido para $NEW_DOMAIN"

      rm -f "$NGINX_TMP"
      [[ -L /etc/nginx/sites-enabled/zaptec-newdomain ]] && rm -f /etc/nginx/sites-enabled/zaptec-newdomain
    else
      info "Certbot desativado nesta instalação — apenas .env será atualizado (configure SSL no proxy reverso)"
    fi

    # Reescrever Nginx (somente se Certbot/nginx ativos nesta VPS)
    if [[ "${USE_CERTBOT:-yes}" == "yes" ]] && command -v nginx &>/dev/null; then
    cat > "$NGINX_CONF_NEW" <<NGINXEOF
# Redireciona domínio antigo para o novo (preserva POSTs com 308)
server {
    listen 80;
    server_name ${OLD_DOMAIN};
    return 301 https://${NEW_DOMAIN}\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name ${OLD_DOMAIN};
    ssl_certificate     /etc/letsencrypt/live/${OLD_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${OLD_DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    # Webhooks e API: 308 preserva o método POST
    location ~* ^/(webhooks|api|socket\.io|media|uploads)/ {
        return 308 https://${NEW_DOMAIN}\$request_uri;
    }
    location / {
        return 301 https://${NEW_DOMAIN}\$request_uri;
    }
}
# Domínio novo — config principal
server {
    listen 80;
    server_name ${NEW_DOMAIN};
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name ${NEW_DOMAIN};
    ssl_certificate     /etc/letsencrypt/live/${NEW_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${NEW_DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_session_cache shared:SSL:10m;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options SAMEORIGIN;
    add_header X-Content-Type-Options nosniff;
    root ${INSTALL_DIR}/frontend/dist;
    index index.html;
    location = /manifest.json {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_set_header Host \$host;
        add_header Cache-Control "no-cache, no-store, must-revalidate" always;
    }
    location /api/ {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        client_max_body_size 50m;
    }
    location /socket.io/ {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 3600s;
    }
    location /media/ {
        proxy_pass http://127.0.0.1:${APP_PORT};
        client_max_body_size 50m;
    }
    location /uploads/ {
        proxy_pass http://127.0.0.1:${APP_PORT};
        client_max_body_size 20m;
    }
    location /webhooks/ {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_set_header Host \$host;
    }
    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
NGINXEOF

    if [[ -d /etc/nginx/sites-enabled ]]; then
      ln -sf "$NGINX_CONF_NEW" /etc/nginx/sites-enabled/zaptec
    fi
    nginx -t && systemctl reload nginx
    log "Nginx recarregado com config do novo domínio"
    fi

    # Atualizar .env com o novo domínio
    sed -i "s|BACKEND_URL=https\?://${OLD_DOMAIN}|BACKEND_URL=https://${NEW_DOMAIN}|g" "$INSTALL_DIR/.env"
    sed -i "s|FRONTEND_URL=https\?://${OLD_DOMAIN}|FRONTEND_URL=https://${NEW_DOMAIN}|g" "$INSTALL_DIR/.env"
    sed -i "s|API_URL=https\?://${OLD_DOMAIN}|API_URL=https://${NEW_DOMAIN}|g" "$INSTALL_DIR/.env"
    sed -i "s|CORS_ORIGIN=https\?://${OLD_DOMAIN}|CORS_ORIGIN=https://${NEW_DOMAIN}|g" "$INSTALL_DIR/.env"
    sed -i "s|GOOGLE_REDIRECT_URI=https\?://${OLD_DOMAIN}|GOOGLE_REDIRECT_URI=https://${NEW_DOMAIN}/api/backup/google/callback|g" "$INSTALL_DIR/.env"
    [[ -f "$INSTALL_DIR/.install-meta" ]] && sed -i "s|^APP_DOMAIN=.*|APP_DOMAIN=${NEW_DOMAIN}|" "$INSTALL_DIR/.install-meta"
    [[ -f "$INSTALL_DIR/.install-meta" ]] && sed -i "s|^PUBLIC_URL=.*|PUBLIC_URL=https://${NEW_DOMAIN}|" "$INSTALL_DIR/.install-meta"
    log ".env atualizado com novo domínio"

    DB_URL=$(grep "^DATABASE_URL=" "$INSTALL_DIR/.env" | cut -d= -f2-)
    DB_NAME=$(echo "$DB_URL" | sed -E 's|.*/([^?]+).*|\1|')
    DB_USER=$(echo "$DB_URL" | sed -E 's|.*://([^:]+):.*|\1|')
    DB_PASS=$(echo "$DB_URL" | sed -E 's|.*://[^:]+:([^@]+)@.*|\1|')

    ROWS=$(docker exec zaptec-db sh -c \
      "PGPASSWORD='${DB_PASS}' psql -U '${DB_USER}' '${DB_NAME}' -t -c \
      \"UPDATE whatsapp_connections SET \\\"notificameWebhookUrl\\\" = REPLACE(\\\"notificameWebhookUrl\\\", 'https://${OLD_DOMAIN}', 'https://${NEW_DOMAIN}') WHERE \\\"notificameWebhookUrl\\\" LIKE '%${OLD_DOMAIN}%'; SELECT ROW_COUNT();\"" 2>/dev/null || echo "0")
    log "Banco atualizado: notificameWebhookUrl migrado ($ROWS conexões)"

    echo ""
    echo -e "  ${YELLOW}${BOLD}⚠  AÇÃO MANUAL após reiniciar o backend:${NC}"
    if [[ "${USE_CERTBOT:-yes}" != "yes" ]]; then
      echo -e "  ${BOLD}1.${NC} Atualizar o proxy reverso para o novo domínio ${NEW_DOMAIN}"
      echo -e "  ${BOLD}2.${NC} Reativar conexões OFFICIAL (webhook Notifica.me)"
    else
      echo -e "  ${BOLD}1.${NC} Reativar conexões OFFICIAL (webhook Notifica.me)"
    fi
    echo -e "  ${BOLD}·${NC} Atualizar webhook AbacatePay: ${CYAN}https://${NEW_DOMAIN}/webhooks/abacatepay?webhookSecret=...${NC}"
    echo ""
  fi
fi

# ─── Recarregar Nginx ─────────────────────────────────────────
if systemctl is-active --quiet nginx; then
  # Garantir que location /uploads/ existe no config (pode faltar em instalações antigas)
  NGINX_CONF=$(find /etc/nginx/sites-enabled /etc/nginx/conf.d -name "*.conf" 2>/dev/null | head -1)
  if [[ -n "$NGINX_CONF" ]] && ! grep -q "location /uploads/" "$NGINX_CONF"; then
    warn "Adicionando location /uploads/ ao nginx (ausente na instalação anterior)..."
    sed -i "/location \/media\/ {/i \\    location /uploads/ {\\n        proxy_pass http://127.0.0.1:${APP_PORT};\\n        client_max_body_size 20m;\\n    }" "$NGINX_CONF"
    log "location /uploads/ adicionado ao nginx"
  fi
  if [[ -n "$NGINX_CONF" ]] && ! grep -q "location = /manifest.json" "$NGINX_CONF"; then
    warn "Adicionando proxy /manifest.json ao nginx (manifest dinâmico)..."
    sed -i "/location \/ {/i \\    location = /manifest.json {\\n        proxy_pass http://127.0.0.1:${APP_PORT};\\n        proxy_set_header Host \\\$host;\\n        add_header Cache-Control \"no-cache, no-store, must-revalidate\" always;\\n    }\\n" "$NGINX_CONF"
    log "location /manifest.json adicionado ao nginx"
  fi
  # Corrigir instalações antigas que ainda apontam nginx para :3000 com porta customizada
  if [[ -n "$NGINX_CONF" && "$APP_PORT" != "3000" ]] && grep -q "127.0.0.1:3000" "$NGINX_CONF"; then
    sed -i "s|127.0.0.1:3000|127.0.0.1:${APP_PORT}|g" "$NGINX_CONF"
    log "Nginx atualizado para porta ${APP_PORT}"
  fi
  nginx -t && systemctl reload nginx
  log "Nginx recarregado"
fi

# ─── Verificar chaves VAPID (push notifications) ──────────────
if ! grep -q "^VAPID_PUBLIC_KEY=.\+" "$INSTALL_DIR/.env" 2>/dev/null; then
  warn "VAPID_PUBLIC_KEY não está configurado no .env — push notifications estão desativadas."
  info "Para ativar, gere as chaves com: node -e \"const w=require('web-push');const k=w.generateVAPIDKeys();console.log(k);\""
  info "Depois adicione VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY e VAPID_EMAIL ao $INSTALL_DIR/.env"
fi

# ─── Limpeza de backups antigos (mantém 14) ───────────────────
ls -t "$BACKUP_DIR"/*.sql.gz 2>/dev/null | tail -n +15 | xargs -r rm
log "Backups antigos removidos (mantidos os últimos 14)"

# ─── Relatório final ───────────────────────────────────────────
section "Atualização Concluída!"

echo ""
echo -e "  ${GREEN}${BOLD}Sistema atualizado com sucesso!${NC}"
echo -e "  ${BOLD}Versão anterior:${NC} $CURRENT_COMMIT"
echo -e "  ${BOLD}Versão atual:${NC}    $NEW_COMMIT"
echo -e "  ${BOLD}Backup salvo em:${NC} $BACKUP_FILE"
echo -e "  ${BOLD}PM2 status:${NC}      pm2 status"
echo -e "  ${BOLD}Logs:${NC}            pm2 logs zaptec-backend"
echo ""
echo -e "${YELLOW}Se algo der errado, restaure com:${NC}"
echo -e "  ${BOLD}zcat $BACKUP_FILE | docker exec -i zaptec-db sh -c \"PGPASSWORD='\$POSTGRES_PASSWORD' psql -U '\$POSTGRES_USER' '\$POSTGRES_DB'\"${NC}"
echo ""
