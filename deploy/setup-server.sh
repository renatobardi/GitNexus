#!/bin/bash
# =============================================================================
# GitNexus — Setup inicial do servidor Oracle Cloud ARM (Ampere A1)
# Compatível com: Oracle Linux 9 / Ubuntu 22.04 (ARM64)
# Rodar uma única vez na criação da instância
# =============================================================================
set -euo pipefail

# Detecta o gerenciador de pacotes
if command -v apt-get &>/dev/null; then
  PKG_MANAGER="apt"
elif command -v dnf &>/dev/null; then
  PKG_MANAGER="dnf"
elif command -v yum &>/dev/null; then
  PKG_MANAGER="yum"
else
  echo "Gerenciador de pacotes não reconhecido. Abortando."
  exit 1
fi

echo "==> Sistema detectado: $PKG_MANAGER"

echo "==> [1/5] Atualizando pacotes e instalando dependências do SO..."
if [ "$PKG_MANAGER" = "apt" ]; then
  sudo apt-get update && sudo apt-get upgrade -y
  sudo apt-get install -y \
    curl git python3 make g++ \
    nginx certbot python3-certbot-nginx \
    htop tmux net-tools \
    netfilter-persistent iptables-persistent
else
  sudo dnf update -y
  sudo dnf install -y \
    curl git python3 python3-pip make gcc gcc-c++ cmake \
    nginx \
    htop tmux net-tools
  # GCC 13 necessário para compilar LadybugDB (requer C++20 <format>)
  sudo dnf install -y gcc-toolset-13-gcc-c++
  # certbot via pip3 (não disponível via dnf no Oracle Linux 9)
  sudo pip3 install certbot certbot-nginx
fi

echo "==> [2/5] Instalando Node.js 20 LTS (ARM64 via NodeSource)..."
if [ "$PKG_MANAGER" = "apt" ]; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
  sudo apt-get install -y nodejs
else
  curl -fsSL https://rpm.nodesource.com/setup_20.x | sudo bash -
  sudo dnf install -y nodejs
fi

echo "==> Verificando versões..."
node --version
npm --version
python3 --version

echo "==> [3/5] Criando usuário e diretório da aplicação..."
if ! id "gitnexus" &>/dev/null; then
  sudo useradd -m -s /bin/bash gitnexus
fi
sudo mkdir -p /opt/gitnexus
sudo chown gitnexus:gitnexus /opt/gitnexus

echo "==> [4/5] Abrindo portas 80 e 443 no firewall..."
if [ "$PKG_MANAGER" = "apt" ]; then
  sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 80 -j ACCEPT
  sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 443 -j ACCEPT
  sudo netfilter-persistent save
else
  # Oracle Linux usa firewalld
  sudo systemctl enable --now firewalld
  sudo firewall-cmd --permanent --add-service=http
  sudo firewall-cmd --permanent --add-service=https
  sudo firewall-cmd --reload
  # iptables também (Oracle Cloud tem regras diretas)
  sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 80 -j ACCEPT
  sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 443 -j ACCEPT
  sudo service iptables save 2>/dev/null || true
fi

echo "==> [5/5] Configurando diretório e SELinux..."
sudo chown -R gitnexus:gitnexus /opt/gitnexus
# Permite nginx fazer proxy para localhost (Oracle Linux tem SELinux ativo)
sudo setsebool -P httpd_can_network_connect 1

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
