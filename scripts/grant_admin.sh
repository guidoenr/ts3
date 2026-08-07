#!/usr/bin/env bash
# Le da "Server Admin" a un cliente ya conocido por el server, buscándolo por nickname.
# Pensado para correrlo vos mismo (no hace falta pedirle a nadie) cuando alguien pierda el
# admin — es común que pase: cualquier admin puede sacarle el grupo a otro sin querer
# mientras explora el panel de permisos. TS3 clásico no tiene un "token maestro" reutilizable
# (las privilege keys son de un solo uso por protocolo) — esto reemplaza esa necesidad.
#
# Uso: scripts/grant_admin.sh <texto del nickname> [PUBLIC_IP] [ssh_key_path]
set -euo pipefail

QUERY="${1:?Uso: $0 <nickname o parte de el> [PUBLIC_IP] [ssh_key_path]}"
IP="${2:-146.181.38.135}"
KEY="${3:-$HOME/.ssh/ts3_oracle}"

ssh -i "$KEY" -o StrictHostKeyChecking=accept-new "ubuntu@$IP" bash -s -- "$QUERY" << 'REMOTE'
set -euo pipefail
QUERY="$1"
ADMIN_PW=$(cd ~/ts3 && sudo docker compose logs teamspeak 2>/dev/null \
  | grep 'loginname=' | sed -E 's/.*password= ?"([^"]+)".*/\1/' | tail -1)

python3 - "$ADMIN_PW" "$QUERY" << 'PYEOF'
import socket, sys, time

pw, query = sys.argv[1], sys.argv[2]
s = socket.create_connection(("127.0.0.1", 10011), timeout=10)
buf = b""


def readline():
    global buf
    while b"\n" not in buf:
        buf += s.recv(4096)
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

lines, _ = send("clientdblist")
rows = []
for l in lines:
    for entry in l.split("|"):
        row = dict(kv.split("=", 1) for kv in entry.split() if "=" in kv)
        if row:
            rows.append(row)

matches = [r for r in rows if query.lower() in r.get("client_nickname", "").replace("\\s", " ").lower()]
if not matches:
    print(f"No encontre ningun cliente que matchee '{query}'. Tiene que haberse conectado al menos una vez.")
    sys.exit(1)
if len(matches) > 1:
    print("Hay mas de un match, se especifico mejor:")
    for m in matches:
        print(" -", m.get("client_nickname", "").replace("\\s", " "), "cldbid=" + m["cldbid"])
    sys.exit(1)

m = matches[0]
cldbid = m["cldbid"]
nick = m.get("client_nickname", "").replace("\\s", " ")
print(f"Dando Server Admin a '{nick}' (cldbid={cldbid})...")
_, err = send(f"servergroupaddclient sgid=6 cldbid={cldbid}")
print(" ", err)
groups, _ = send(f"servergroupsbyclientid cldbid={cldbid}")
print(" confirmado:", groups)
PYEOF
REMOTE
