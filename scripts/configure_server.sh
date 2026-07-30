#!/usr/bin/env bash
# Corre esto en la VM despues de bootstrap.sh (remote_deploy.sh ya lo encadena solo).
# Configura el virtual server 1 la primera vez que arranca: nombre, password, canales, y el
# grupo default para gente nueva (Guest por defecto - ver TS3_EVERYONE_ADMIN mas abajo).
# El owner se vuelve admin con la privilege key de los logs (Paso 5 del README), como en
# cualquier server TS3 estandar; despues puede promover a quien quiera desde el cliente.
#
# Es un paso de una sola vez: si el server ya tiene el login de serveradmin (porque ya se
# corrio antes), no vuelve a aparecer en los logs y este script se sale sin romper nada.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

SERVER_NAME="${TS3_SERVER_NAME:-el SERVER del guidoti}"
SERVER_PASSWORD="${TS3_SERVER_PASSWORD:-asdf}"
CHANNEL_1="${TS3_CHANNEL_1:-LOBBYS}"
CHANNEL_2="${TS3_CHANNEL_2:-MIX10-Team1}"
CHANNEL_3="${TS3_CHANNEL_3:-MIX10-Team2}"
EVERYONE_ADMIN="${TS3_EVERYONE_ADMIN:-false}"

echo "==> Buscando la contrasena de serveradmin en los logs..."
ADMIN_PASSWORD=""
for _ in $(seq 1 30); do
  ADMIN_PASSWORD=$(sudo docker compose logs teamspeak 2>/dev/null \
    | grep 'loginname=' \
    | sed -E 's/.*password= ?"([^"]+)".*/\1/' \
    | tail -1)
  [ -n "$ADMIN_PASSWORD" ] && break
  sleep 2
done

if [ -z "$ADMIN_PASSWORD" ]; then
  echo "    No encontre credenciales de serveradmin nuevas en los logs (probablemente el server"
  echo "    ya se configuro en un boot anterior). Salteo la configuracion, no toco nada."
  exit 0
fi

echo "==> Esperando a que ServerQuery (10011) responda..."
for _ in $(seq 1 30); do
  (echo > /dev/tcp/127.0.0.1/10011) 2>/dev/null && break
  sleep 2
done

echo "==> Aplicando configuracion via ServerQuery..."
python3 "$REPO_DIR/scripts/ts3_configure.py" \
  "$ADMIN_PASSWORD" "$SERVER_NAME" "$SERVER_PASSWORD" "$CHANNEL_1" "$CHANNEL_2" "$CHANNEL_3" "$EVERYONE_ADMIN"

echo "==> Server configurado: '$SERVER_NAME', canales [$CHANNEL_1, $CHANNEL_2, $CHANNEL_3], password del server '$SERVER_PASSWORD'."
