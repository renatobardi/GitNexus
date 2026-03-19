#!/bin/bash
# =============================================================================
# GitNexus — Clone, build e instalação inicial
# Rodar uma única vez após setup-server.sh
# =============================================================================
set -euo pipefail

APP_DIR=/opt/gitnexus
REPO_URL=https://github.com/renatobardi/GitNexus.git

echo "==> [1/6] Clonando repositório em ${APP_DIR}/app..."
sudo -u gitnexus git clone "$REPO_URL" "${APP_DIR}/app"
cd "${APP_DIR}/app"

echo "==> [2/6] Instalando dependências npm (sem executar scripts ainda)..."
# --ignore-scripts: controla o rebuild de native addons manualmente
sudo -u gitnexus npm ci --ignore-scripts

echo "==> [3/6] Aplicando patch tree-sitter-swift (ARM64 fix)..."
# Remove pre-build actions do binding.gyp que falham em alguns ambientes ARM
sudo -u gitnexus node scripts/patch-tree-sitter-swift.cjs

echo "==> [4/6] Compilando todos os native addons para ARM64..."
sudo -u gitnexus npm rebuild

# tree-sitter-kotlin precisa de rebuild manual (não obedece npm rebuild global)
echo "    → Compilando tree-sitter-kotlin manualmente..."
cd "${APP_DIR}/app/node_modules/tree-sitter-kotlin"
sudo -u gitnexus npx node-gyp rebuild
cd "${APP_DIR}/app"

echo "==> [5/6] Verificando native addons..."
sudo -u gitnexus node -e "require('@ladybugdb/core'); console.log('  ✓ LadybugDB OK')"
sudo -u gitnexus node -e "require('tree-sitter'); console.log('  ✓ tree-sitter OK')"
echo "  ✓ Todos os native addons compilados com sucesso"

echo "==> [6/6] Compilando TypeScript..."
# Build do CLI/MCP server
sudo -u gitnexus npm run build --workspace=gitnexus
echo "  ✓ gitnexus (CLI + MCP server) compilado"

# Build do Web UI
sudo -u gitnexus npm run build --workspace=gitnexus-web
echo "  ✓ gitnexus-web (React UI) compilado"

echo ""
echo "=============================================="
echo "Deploy inicial concluído!"
echo ""
echo "Próximos passos:"
echo "  1. Instalar o serviço systemd:"
echo "     sudo cp deploy/gitnexus.service /etc/systemd/system/"
echo "     sudo systemctl daemon-reload"
echo "     sudo systemctl enable --now gitnexus"
echo ""
echo "  2. Configurar Nginx:"
echo "     sudo cp deploy/nginx-gitnexus.conf /etc/nginx/sites-available/gitnexus"
echo "     sudo ln -s /etc/nginx/sites-available/gitnexus /etc/nginx/sites-enabled/"
echo "     sudo nginx -t && sudo systemctl reload nginx"
echo ""
echo "  3. Obter certificado SSL:"
echo "     sudo certbot --nginx -d nexus.oute.pro"
echo "=============================================="
