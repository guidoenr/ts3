#!/usr/bin/env bash
# Corre en la VM. Re-asegura que las identidades "owner" conocidas (por cldbid) tengan el
# grupo "Owner" (sgid=9, creado a mano con permisos de gestion de grupo por encima de
# "Server Admin" - ver README). Pensado para invocarse periodicamente desde
# .github/workflows/ensure-owner.yml como red de seguridad extra, ademas de la proteccion
# de permisos del grupo Owner en si (que ya deberia impedir que otro admin te sacara).
# Idempotente: si ya son miembros, tira "duplicate entry" y no rompe nada.
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

OWNER_SGID="${TS3_OWNER_SGID:-9}"
OWNER_CLDBIDS="${TS3_OWNER_CLDBIDS:-3,4}"

ADMIN_PASSWORD=$(sudo docker compose logs teamspeak 2>/dev/null \
  | grep 'loginname=' | sed -E 's/.*password= ?"([^"]+)".*/\1/' | tail -1)
if [ -z "$ADMIN_PASSWORD" ]; then
  echo "No pude sacar la password de serveradmin de los logs" >&2
  exit 1
fi

python3 - "$ADMIN_PASSWORD" "$OWNER_SGID" "$OWNER_CLDBIDS" << 'PYEOF'
import socket
import sys
import time

pw, sgid, cldbids = sys.argv[1], sys.argv[2], sys.argv[3].split(",")
s = socket.create_connection(("127.0.0.1", 10011), timeout=10)
buf = b""


def readline():
    global buf
    while b"\n" not in buf:
        chunk = s.recv(4096)
        if not chunk:
            raise ConnectionError("closed")
        buf += chunk
    line, buf = buf.split(b"\n", 1)
    return line.decode("utf-8", "replace").strip("\r")


def send(cmd):
    s.sendall((cmd + "\n\r").encode())
    lines = []
    while True:
        line = readline()
        if line.startswith("error "):
            return lines, line
        if line:
            lines.append(line)


time.sleep(0.3)
readline()
send(f"login client_login_name=serveradmin client_login_password={pw}")
send("use sid=1")
for cldbid in cldbids:
    cldbid = cldbid.strip()
    if not cldbid:
        continue
    _, err = send(f"servergroupaddclient sgid={sgid} cldbid={cldbid}")
    print(f"cldbid={cldbid}: {err}")
PYEOF
