#!/bin/bash
# =============================================================================
# GitNexus — Atualização da aplicação no servidor Oracle Cloud
# Executado pelo CI/CD (GitHub Actions) ou manualmente
# =============================================================================
set -euo pipefail

APP_DIR=/opt/gitnexus/app

echo "==> [1/6] Atualizando código-fonte..."
cd "$APP_DIR"
sudo -u gitnexus git pull origin main

echo "==> [2/6] Instalando dependências npm (sem executar scripts)..."
sudo -u gitnexus npm ci --ignore-scripts

echo "==> [3/6] Aplicando patch tree-sitter-swift (ARM64 fix)..."
sudo -u gitnexus node scripts/patch-tree-sitter-swift.cjs

echo "==> [4/6] Compilando native addons para ARM64..."
sudo -u gitnexus npm rebuild

# tree-sitter-kotlin precisa rebuild manual
echo "    → Recompilando tree-sitter-kotlin..."
cd "${APP_DIR}/node_modules/tree-sitter-kotlin"
sudo -u gitnexus npx node-gyp rebuild
cd "$APP_DIR"

echo "==> [5/6] Compilando TypeScript..."
sudo -u gitnexus npm run build --workspace=gitnexus
sudo -u gitnexus npm run build --workspace=gitnexus-web

echo "==> [6/6] Reiniciando serviço systemd..."
sudo systemctl restart gitnexus
sudo systemctl status gitnexus --no-pager

echo ""
echo "=============================================="
echo "GitNexus atualizado e reiniciado com sucesso!"
echo "Health check: curl http://localhost:4747/api/repos"
echo "=============================================="
