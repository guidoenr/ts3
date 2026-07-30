#!/usr/bin/env python3
"""Configura el virtual server 1 via ServerQuery (puerto 10011) recien arrancado por primera vez.

Uso: ts3_configure.py <serveradmin_password> <server_name> <server_password> <canal1> <canal2> <canal3>

No requiere librerias externas: habla el protocolo ServerQuery a mano por un socket TCP.
"""
import socket
import sys
import time

HOST, PORT = "127.0.0.1", 10011


def escape(value):
    # Orden importa: la barra invertida primero, para no doble-escapar lo que sigue.
    replacements = [
        ("\\", "\\\\"),
        ("/", "\\/"),
        (" ", "\\s"),
        ("|", "\\p"),
        ("\a", "\\a"),
        ("\b", "\\b"),
        ("\f", "\\f"),
        ("\n", "\\n"),
        ("\r", "\\r"),
        ("\t", "\\t"),
        ("\v", "\\v"),
    ]
    for src, dst in replacements:
        value = value.replace(src, dst)
    return value


class ServerQuery:
    def __init__(self, sock):
        self.sock = sock
        self.buf = b""

    def _readline(self):
        while b"\n" not in self.buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("conexion cerrada por el server")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return line.decode("utf-8", "replace").strip("\r")

    def _send_once(self, command):
        self.sock.sendall((command + "\n\r").encode("utf-8"))
        lines = []
        while True:
            line = self._readline()
            if line.startswith("error "):
                parts = dict(kv.split("=", 1) for kv in line.split()[1:] if "=" in kv)
                return parts, lines
            if line:
                lines.append(line)

    def send(self, command):
        # ServerQuery tiene proteccion anti-flood (por default ~1 comando cada 350ms).
        # Reintenta con el backoff que el propio server pide en "extra_msg=please\swait\sN\sseconds".
        for _ in range(10):
            parts, lines = self._send_once(command)
            if parts.get("id") == "0":
                return lines
            if parts.get("id") != "524":
                raise RuntimeError(f"comando '{command}' fallo: id={parts.get('id')} msg={parts.get('msg')}")
            wait_s = 1.0
            extra = parts.get("extra_msg", "").replace("\\s", " ")
            for token in extra.split():
                if token.isdigit():
                    wait_s = float(token)
                    break
            time.sleep(wait_s + 0.1)
        raise RuntimeError(f"comando '{command}' rechazado por flood-protection tras varios reintentos")

    def read_banner(self):
        # El server manda un banner de bienvenida de varias lineas antes de aceptar comandos.
        deadline = time.time() + 5
        while time.time() < deadline:
            line = self._readline()
            if "TS3" in line or line == "":
                break


def parse_kv_lines(lines):
    # Cada linea de ServerQuery puede traer varios registros separados por "|"
    # (ej. channellist devuelve todos los canales en una sola linea) - cada
    # segmento es una fila independiente, no hay que mezclar sus campos.
    rows = []
    for line in lines:
        for entry in line.split("|"):
            row = {}
            for kv in entry.split():
                if "=" in kv:
                    k, v = kv.split("=", 1)
                    row[k] = v
            if row:
                rows.append(row)
    return rows


def main():
    if len(sys.argv) != 7:
        print(f"Uso: {sys.argv[0]} <serveradmin_password> <server_name> <server_password> <canal1> <canal2> <canal3>", file=sys.stderr)
        sys.exit(1)

    admin_password, server_name, server_password, ch1, ch2, ch3 = sys.argv[1:7]

    sock = socket.create_connection((HOST, PORT), timeout=10)
    sq = ServerQuery(sock)
    sq.read_banner()

    print("==> login serveradmin")
    sq.send(f"login client_login_name=serveradmin client_login_password={escape(admin_password)}")

    print("==> use sid=1")
    sq.send("use sid=1")

    print(f"==> configurando nombre '{server_name}' y password del server")
    sq.send(
        "serveredit "
        f"virtualserver_name={escape(server_name)} "
        f"virtualserver_password={escape(server_password)}"
    )

    print("==> buscando el canal default")
    channels = parse_kv_lines(sq.send("channellist -flags"))
    existing_names = {c.get("channel_name", "").replace("\\s", " ") for c in channels}
    default = next((c for c in channels if c.get("channel_flag_default") == "1"), channels[0])
    default_cid = default["cid"]

    default_name = default.get("channel_name", "").replace("\\s", " ")
    if default_name == ch1:
        print(f"==> canal default ya se llama '{ch1}', no hace falta renombrar")
    else:
        print(f"==> renombrando canal default (cid={default_cid}) a '{ch1}'")
        sq.send(f"channeledit cid={default_cid} channel_name={escape(ch1)}")
    existing_names.add(ch1)

    for name in (ch2, ch3):
        if name in existing_names:
            print(f"==> canal '{name}' ya existe, no lo vuelvo a crear")
            continue
        print(f"==> creando canal '{name}'")
        sq.send(f"channelcreate channel_name={escape(name)} cpid=0 channel_flag_permanent=1")

    print("==> buscando el grupo 'Server Admin'")
    groups = parse_kv_lines(sq.send("servergrouplist"))
    admin_group = next(
        (
            g
            for g in groups
            if g.get("name", "").replace("\\s", " ") == "Server Admin" and g.get("type") == "1"
        ),
        None,
    )
    if admin_group is None:
        print("ATENCION: no encontre el grupo 'Server Admin', salteo el paso de admin-para-todos", file=sys.stderr)
    else:
        sgid = admin_group["sgid"]
        print(f"==> seteando '{sgid}' (Server Admin) como grupo default de todo el que se conecta")
        sq.send(f"serveredit virtualserver_default_server_group={sgid}")

    sq.send("quit")
    print("==> listo")


if __name__ == "__main__":
    main()
