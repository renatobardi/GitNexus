#!/bin/bash
# =============================================================================
# GitNexus — Clone, build e instalação inicial
# Rodar uma única vez após setup-server.sh
# =============================================================================
set -euo pipefail

APP_DIR=/opt/gitnexus
REPO_URL=https://github.com/renatobardi/GitNexus.git
GCC13=/opt/rh/gcc-toolset-13/root/usr/bin

echo "==> [1/7] Clonando repositório em ${APP_DIR}/app..."
sudo -u gitnexus git clone "$REPO_URL" "${APP_DIR}/app"

echo "==> [2/7] Instalando dependências (gitnexus)..."
cd "${APP_DIR}/app/gitnexus"
sudo -u gitnexus npm ci --ignore-scripts

echo "==> [3/7] Corrigindo tree-sitter-swift binding.gyp (ARM64)..."
# O patch script falha com trailing commas no JSON — sobrescreve diretamente
sudo -u gitnexus tee node_modules/tree-sitter-swift/binding.gyp > /dev/null << 'BINDEOF'
{
  "targets": [
    {
      "target_name": "tree_sitter_swift_binding",
      "dependencies": [
        "<!(node -p \"require('node-addon-api').targets\"):node_addon_api_except"
      ],
      "include_dirs": [
        "src"
      ],
      "sources": [
        "bindings/node/binding.cc",
        "src/parser.c",
        "src/scanner.c"
      ],
      "cflags_c": [
        "-std=c11"
      ]
    }
  ]
}
BINDEOF

echo "==> [4/7] Compilando native addons para ARM64..."
sudo -u gitnexus npm rebuild

# tree-sitter-kotlin precisa rebuild manual
echo "    → Compilando tree-sitter-kotlin manualmente..."
cd "${APP_DIR}/app/gitnexus/node_modules/tree-sitter-kotlin"
sudo -u gitnexus npx node-gyp rebuild

echo "==> [5/7] Compilando LadybugDB do source (requer GCC 13 / C++20)..."
# O prebuilt requer GLIBC 2.38, Oracle Linux 9 tem 2.34 — compila do source
LBUG_SOURCE="${APP_DIR}/app/gitnexus/node_modules/@ladybugdb/core/lbug-source"
cd "$LBUG_SOURCE"
sudo -u gitnexus NODE_PATH="${APP_DIR}/app/gitnexus/node_modules" CXX="${GCC13}/g++" CC="${GCC13}/gcc" make nodejs NUM_THREADS=4
sudo -u gitnexus cp tools/nodejs_api/build/lbugjs.node ../lbugjs.node
echo "    ✓ LadybugDB compilado com sucesso"

echo "==> [6/7] Compilando TypeScript (gitnexus)..."
cd "${APP_DIR}/app/gitnexus"
sudo -u gitnexus npm run build
echo "    ✓ gitnexus (CLI + MCP server) compilado"

echo "==> [7/7] Compilando Web UI (gitnexus-web)..."
cd "${APP_DIR}/app/gitnexus-web"
sudo -u gitnexus npm ci
sudo -u gitnexus npm run build
echo "    ✓ gitnexus-web (React UI) compilado"

echo ""
echo "=============================================="
echo "Deploy inicial concluído!"
echo ""
echo "Próximos passos:"
echo "  1. Instalar o serviço systemd:"
echo "     sudo tee /etc/systemd/system/gitnexus.service < deploy/gitnexus.service"
echo "     sudo systemctl daemon-reload"
echo "     sudo systemctl enable --now gitnexus"
echo ""
echo "  2. Configurar Nginx (Oracle Linux usa conf.d, não sites-enabled):"
echo "     sudo cp deploy/nginx-gitnexus.conf /etc/nginx/conf.d/gitnexus.conf"
echo "     sudo setsebool -P httpd_can_network_connect 1"
echo "     sudo nginx -t && sudo systemctl reload nginx"
echo ""
echo "  3. Obter certificado SSL:"
echo "     sudo /usr/local/bin/certbot --nginx -d nexus.oute.pro"
echo "=============================================="
