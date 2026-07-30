#!/usr/bin/env bash
# Dado la IP pública de una instancia ya creada (ver provision_oracle.sh), espera a que SSH
# esté listo y corre el deploy completo ahí: clona/actualiza el repo y ejecuta bootstrap.sh.
# Uso: scripts/remote_deploy.sh <PUBLIC_IP> [ssh_key_path] [repo_url]
set -euo pipefail

IP="${1:?Uso: $0 <PUBLIC_IP> [ssh_key_path] [repo_url]}"
KEY="${2:-$HOME/.ssh/ts3_oracle}"
REPO_URL="${3:-https://github.com/guidoenr/ts3.git}"
SSH_OPTS=(-i "$KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

echo "==> Esperando a que el puerto 22 de $IP responda..."
until (echo > "/dev/tcp/$IP/22") 2>/dev/null; do
  sleep 5
done
echo "    puerto 22 abierto."

echo "==> Esperando a que SSH acepte login (cloud-init puede tardar un poco más que el puerto)..."
attempt=0
until ssh "${SSH_OPTS[@]}" "ubuntu@$IP" "echo ok" >/dev/null 2>&1; do
  attempt=$((attempt+1))
  if [ "$attempt" -ge 24 ]; then
    echo "ERROR: no pude loguear por SSH después de varios intentos (2 min)." >&2
    exit 1
  fi
  sleep 5
done
echo "    login OK."

echo "==> Clonando/actualizando el repo y corriendo bootstrap.sh en la VM..."
ssh "${SSH_OPTS[@]}" "ubuntu@$IP" bash -s << REMOTE
set -euo pipefail
if [ -d ts3/.git ]; then
  cd ts3 && git pull --ff-only
else
  git clone "$REPO_URL" ts3
  cd ts3
fi
chmod +x scripts/bootstrap.sh scripts/configure_server.sh
./scripts/bootstrap.sh
./scripts/configure_server.sh
REMOTE

echo ""
echo "==> Deploy listo. Credenciales de admin (Oracle/TS3 las muestra una sola vez en los logs):"
ssh "${SSH_OPTS[@]}" "ubuntu@$IP" "cd ts3 && sudo docker compose logs teamspeak 2>/dev/null | grep -E 'loginname|token=' || true"
