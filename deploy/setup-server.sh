#!/bin/bash
# =============================================================================
# GitNexus — Setup inicial do servidor Oracle Cloud ARM (Ampere A1)
# Rodar uma única vez na criação da instância (Ubuntu 22.04 LTS ARM64)
# =============================================================================
set -euo pipefail

echo "==> [1/5] Atualizando pacotes e instalando dependências do SO..."
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get install -y \
  curl git python3 make g++ \
  nginx certbot python3-certbot-nginx \
  htop tmux net-tools \
  netfilter-persistent iptables-persistent

echo "==> [2/5] Instalando Node.js 20 LTS (ARM64 via NodeSource)..."
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs

echo "==> Verificando versões..."
node --version
npm --version
python3 --version
g++ --version

echo "==> [3/5] Criando usuário e diretório da aplicação..."
if ! id "gitnexus" &>/dev/null; then
  sudo useradd -m -s /bin/bash gitnexus
fi
sudo mkdir -p /opt/gitnexus
sudo chown gitnexus:gitnexus /opt/gitnexus

echo "==> [4/5] Abrindo portas 80 e 443 no iptables (Oracle Cloud bloqueia por padrão)..."
sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 80 -j ACCEPT
sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 443 -j ACCEPT
sudo netfilter-persistent save

echo "==> [5/5] Configurando diretório da aplicação para o usuário gitnexus..."
sudo chown -R gitnexus:gitnexus /opt/gitnexus

echo ""
echo "=============================================="
echo "Setup concluído!"
echo ""
echo "Próximos passos:"
echo "  1. Adicione regras de ingress na Security List da Oracle Cloud:"
echo "     - TCP 80  (HTTP)  — 0.0.0.0/0"
echo "     - TCP 443 (HTTPS) — 0.0.0.0/0"
echo "  2. Aponte nexus.oute.pro para o IP público desta VM"
echo "  3. Execute: bash deploy/deploy-app.sh"
echo "=============================================="
