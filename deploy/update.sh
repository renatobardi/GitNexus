#!/bin/bash
# =============================================================================
# GitNexus — Atualização da aplicação no servidor Oracle Cloud
# Executado pelo CI/CD (GitHub Actions) ou manualmente
# =============================================================================
set -euo pipefail

APP_DIR=/opt/gitnexus/app
GCC13=/opt/rh/gcc-toolset-13/root/usr/bin
SWIFT_BINDING_GYP="${APP_DIR}/gitnexus/node_modules/tree-sitter-swift/binding.gyp"
LBUG_SOURCE="${APP_DIR}/gitnexus/node_modules/@ladybugdb/core/lbug-source"
LBUG_BUILT="${LBUG_SOURCE}/tools/nodejs_api/build/lbugjs.node"
LBUG_DEST="${APP_DIR}/gitnexus/node_modules/@ladybugdb/core/lbugjs.node"

echo "==> [1/7] Atualizando código-fonte..."
cd "$APP_DIR"
sudo -u gitnexus git pull origin main

echo "==> [2/7] Instalando dependências (gitnexus)..."
cd "${APP_DIR}/gitnexus"
sudo -u gitnexus npm ci --ignore-scripts

echo "==> [3/7] Corrigindo tree-sitter-swift binding.gyp (ARM64)..."
# O patch script falha com trailing commas — sobrescreve diretamente
sudo -u gitnexus tee "$SWIFT_BINDING_GYP" > /dev/null << 'BINDEOF'
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
cd "${APP_DIR}/gitnexus"
sudo -u gitnexus npm rebuild

# tree-sitter-kotlin precisa rebuild manual
echo "    → Recompilando tree-sitter-kotlin..."
cd "${APP_DIR}/gitnexus/node_modules/tree-sitter-kotlin"
sudo -u gitnexus npx node-gyp rebuild

echo "==> [5/7] Compilando LadybugDB do source (requer GCC 13 / C++20)..."
cd "$LBUG_SOURCE"
sudo rm -rf build

NODE_VER=$(sudo -u gitnexus node --version | sed 's/v//')
NODE_CACHE_INC="/home/gitnexus/.cmake-js/node-arm64/v${NODE_VER}/include/node"
NAPI_INC="${APP_DIR}/gitnexus/node_modules/node-addon-api"

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
echo "    → lbugjs.node compilado e instalado"

echo "==> [6/7] Compilando TypeScript (gitnexus)..."
cd "${APP_DIR}/gitnexus"
sudo -u gitnexus npm run build

echo "==> [6/7] Compilando Web UI (gitnexus-web)..."
cd "${APP_DIR}/gitnexus-web"
sudo -u gitnexus npm ci
sudo -u gitnexus npm run build

echo "==> [7/7] Reiniciando serviço systemd..."
sudo systemctl restart gitnexus
sleep 3
sudo systemctl status gitnexus --no-pager | head -10

echo ""
echo "=============================================="
echo "GitNexus atualizado e reiniciado com sucesso!"
echo "Health check: curl http://localhost:4747/api/repos"
echo "=============================================="
