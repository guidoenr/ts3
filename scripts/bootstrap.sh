#!/usr/bin/env bash
# Corre esto en la VM de Oracle recién creada (Ubuntu 22.04/24.04), vía SSH.
# Instala Docker, abre los puertos de TS3 en el firewall del SO y levanta el compose.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> Instalando Docker Engine + Compose plugin"
if ! command -v docker >/dev/null 2>&1; then
  sudo apt-get update -y
  sudo apt-get install -y ca-certificates curl gnupg
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update -y
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  sudo usermod -aG docker "$USER"
  echo "    Docker instalado. Puede que necesites cerrar sesión SSH y volver a entrar para usar docker sin sudo."
else
  echo "    Docker ya estaba instalado, salteo este paso."
fi

echo "==> Abriendo puertos de TeamSpeak en iptables (gotcha conocido de las imágenes Ubuntu de OCI)"
sudo apt-get install -y iptables-persistent netfilter-persistent >/dev/null 2>&1 || true

add_rule () {
  local proto="$1" port="$2"
  if ! sudo iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null; then
    sudo iptables -I INPUT -p "$proto" --dport "$port" -j ACCEPT
  fi
}
add_rule udp 9987
add_rule tcp 10011
add_rule tcp 30033
sudo netfilter-persistent save

echo "==> Levantando docker compose"
cd "$REPO_DIR"
if [ ! -f .env ]; then
  cp .env.example .env
  echo "    Creé .env a partir de .env.example (TS3SERVER_LICENSE=accept)."
fi
sudo docker compose pull
sudo docker compose up -d

echo "==> Listo. Mirá los logs para sacar la contraseña de serveradmin y el privilege key (solo se muestran una vez):"
echo "    sudo docker compose logs teamspeak | grep -E 'loginname|token='"
