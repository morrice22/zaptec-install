#!/bin/bash
# =============================================================
# ZapTec SaaS - Script de Atualização (SEM PERDA DE DADOS)
#
# Este script fica no repo PUBLICO: morrice22/zaptec-install
#
# COMO USAR na VPS:
#   curl -sSL https://raw.githubusercontent.com/morrice22/zaptec-install/main/update.sh | sudo bash
#
# Ou com versão específica:
#   VERSION=v2.1.0 curl -sSL https://raw.githubusercontent.com/morrice22/zaptec-install/main/update.sh | sudo bash
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

echo -e "${BOLD}${CYAN}"
echo "  ╔══════════════════════════════════════════════╗"
echo "  ║       ZapTec SaaS - Atualização do Sistema  ║"
echo "  ║       Branch/Versão: $GITHUB_BRANCH              ║"
echo "  ╚══════════════════════════════════════════════╝"
echo -e "${NC}"

# ─── Verificações ─────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Execute como root: sudo bash update.sh"
[[ ! -d "$INSTALL_DIR" ]] && error "Instalação não encontrada em $INSTALL_DIR. Use install.sh primeiro."
[[ ! -f "$INSTALL_DIR/.env" ]] && error "Arquivo .env não encontrado. A instalação pode estar incompleta."

# ─── Verificar serviços dependentes ────────────────────────────
section "Verificando Serviços"

if ! docker compose -f "$INSTALL_DIR/docker-compose.prod.yml" ps postgres | grep -q "running\|Up"; then
  error "PostgreSQL não está rodando! Inicie o banco antes de atualizar."
fi
log "PostgreSQL: rodando"

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
DB_HOST=$(echo "$DB_URL" | sed -E 's|.*@([^:/]+).*|\1|')
DB_PORT=$(echo "$DB_URL" | sed -E 's|.*:([0-9]+)/.*|\1|')
DB_NAME=$(echo "$DB_URL" | sed -E 's|.*/([^?]+).*|\1|')
DB_USER=$(echo "$DB_URL" | sed -E 's|.*://([^:]+):.*|\1|')
DB_PASS=$(echo "$DB_URL" | sed -E 's|.*://[^:]+:([^@]+)@.*|\1|')

BACKUP_FILE="$BACKUP_DIR/pre_update_${DATE}.sql.gz"
PGPASSWORD="$DB_PASS" pg_dump -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" "$DB_NAME" \
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

# Restaura o .env (nunca sobrescrever com pull)
git checkout -- .env 2>/dev/null || true

# ─── Atualizar dependências do backend ────────────────────────
section "Atualizando Dependências"

npm ci --quiet
log "Dependências do backend atualizadas"

# ─── Rodar migrations (SEGURO - apenas adiciona, nunca apaga dados) ─
section "Aplicando Migrations do Banco"

# Regenera o Prisma client com o schema atualizado
npx prisma generate

# migrate deploy: aplica apenas migrations novas, NUNCA desfaz dados existentes
npx prisma migrate deploy
log "Migrations aplicadas com segurança (dados preservados)"

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

# ─── Reiniciar aplicação via PM2 ───────────────────────────────
section "Reiniciando Serviço"

if pm2 list | grep -q "zaptec-backend"; then
  pm2 reload zaptec-backend --update-env
  log "Backend recarregado via PM2 (zero downtime)"
else
  pm2 start ecosystem.config.js
  pm2 save
  log "Backend iniciado via PM2"
fi

# ─── Recarregar Nginx ─────────────────────────────────────────
if systemctl is-active --quiet nginx; then
  nginx -t && systemctl reload nginx
  log "Nginx recarregado"
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
echo -e "  ${BOLD}PGPASSWORD='$DB_PASS' psql -h $DB_HOST -p $DB_PORT -U $DB_USER $DB_NAME < <(zcat $BACKUP_FILE)${NC}"
echo ""
