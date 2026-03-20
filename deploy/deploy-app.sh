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
LBUG_DEST="${APP_DIR}/app/gitnexus/node_modules/@ladybugdb/core/lbugjs.node"
cd "$LBUG_SOURCE"
sudo rm -rf build

NODE_VER=$(sudo -u gitnexus node --version | sed 's/v//')
NODE_CACHE_INC="/home/gitnexus/.cmake-js/node-arm64/v${NODE_VER}/include/node"
NAPI_INC="${APP_DIR}/app/gitnexus/node_modules/node-addon-api"

# Estratégia dupla para resolver napi.h:
# 1) Copiar headers do node-addon-api para o cache do cmake-js (que está em CMAKE_JS_INC)
#    cmake-js sobrescreve CMAKE_JS_INC mas não remove o que já está no diretório
[ -d "${NODE_CACHE_INC}" ] && sudo cp "${NAPI_INC}"/*.h "${NODE_CACHE_INC}/" 2>/dev/null || true
# 2) Adicionar via CMAKE_CXX_FLAGS — cmake-js apenas apenda, nunca sobrescreve
sudo -u gitnexus \
  CXX="${GCC13}/g++" CC="${GCC13}/gcc" \
  cmake -B build/release -DCMAKE_BUILD_TYPE=Release -DBUILD_NODEJS=TRUE \
    "-DCMAKE_CXX_FLAGS=-I${NAPI_INC}" \
    .

sudo -u gitnexus \
  CXX="${GCC13}/g++" CC="${GCC13}/gcc" \
  cmake --build build/release --config Release -j4

LBUG_FOUND=$(find build/release -name "lbugjs.node" 2>/dev/null | head -1)
[ -z "$LBUG_FOUND" ] && { echo "ERROR: lbugjs.node não encontrado após build"; exit 1; }
sudo -u gitnexus cp "$LBUG_FOUND" "$LBUG_DEST"
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
