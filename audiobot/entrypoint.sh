#!/bin/sh
# Siembra la config minima en el volumen de datos SOLO la primera vez (si ya existen los
# archivos, no los toca - para no pisar cambios que se hayan hecho en vivo por chat/WebAPI,
# como "!bot name" o "!settings set").
set -eu

mkdir -p /data/bots/default

if [ ! -f /data/bots/default/bot.toml ]; then
  # Escapa \ y " para que una password con esos caracteres no rompa el TOML.
  ESCAPED_PW=$(printf '%s' "${TS3AB_SERVER_PASSWORD:-}" | sed 's/\\/\\\\/g; s/"/\\"/g')
  cat > /data/bots/default/bot.toml << EOF
run = true

[connect]
# 127.0.0.1 porque este container comparte la red del servicio "teamspeak"
# (network_mode: service:teamspeak en el compose) - los builds de TS3AudioBot no resuelven
# bien nombres de servicio de Docker Compose (DNS del build self-contained), asi que se
# probo primero con el nombre del servicio y fallaba con "Could not read or resolve address".
address = "127.0.0.1:9987"
name = "AudioBot"
server_password = { pw = "${ESCAPED_PW}", hashed = false, autohash = false }

[commands.alias]
tema = "!xecute (!search from youtube (!arg 0)) (!search play 0)"

[audio]
bitrate = 96
EOF
fi

if [ ! -f /data/ts3audiobot.toml ]; then
  cat > /data/ts3audiobot.toml << 'EOF'
[tools.ffmpeg]
path = "ffmpeg"

[tools.youtube-dl]
# Tiene que ser ruta absoluta: TS3AudioBot no busca en $PATH, hace un chequeo de archivo
# literal sobre este valor (un "yt-dlp" a secas resuelve contra el cwd del bot, no contra
# el PATH, y siempre tira "Youtube-Dl could not be found").
path = "/usr/local/bin/yt-dlp"
EOF
fi

# Placeholder valido (vacio) si todavia no se subieron cookies reales - asi yt-dlp no
# rompe por "file not found" antes de que existan. Para actualizar cookies (se vencen o
# YouTube las invalida cada tanto), solo hay que pisar este archivo con uno nuevo, nada mas
# que tocar. Nunca se genera desde git/la imagen: se sube aparte, a mano, directo al volumen.
if [ ! -f /data/cookies.txt ]; then
  cat > /data/cookies.txt << 'EOF'
# Netscape HTTP Cookie File
EOF
fi

# yt-dlp no tiene una config propia dentro del toml del bot - se le pasan flags globales
# via su propio archivo de config, que lee automaticamente sin que el bot sepa nada de esto.
# player_client=web porque el que usa por default (visionos) ni siquiera intenta pedir
# el token del pot-provider y tira LOGIN_REQUIRED directo.
if [ ! -f /root/.config/yt-dlp/config ]; then
  mkdir -p /root/.config/yt-dlp
  cat > /root/.config/yt-dlp/config << 'EOF'
--cookies /data/cookies.txt
--extractor-args "youtube:player_client=web"
EOF
fi

if [ ! -f /data/rights.toml ]; then
  cat > /data/rights.toml << 'EOF'
# Generado una sola vez por entrypoint.sh. Referencia de sintaxis:
# https://github.com/Splamy/TS3AudioBot/wiki/Rights

"+" = [
	"cmd.help.*",
	"cmd.pm",
	"cmd.subscribe",
	"cmd.unsubscribe",
	"cmd.kickme.*",
	"cmd.version",
	"cmd.song",
	"cmd.repeat",
	"cmd.random",
	"cmd.if",
	"cmd.print",
	"cmd.rng",
	"cmd.eval",
	"cmd.take",
	"cmd.xecute",
	"cmd.param",
	"cmd.getmy.*",
	"cmd.json.*",
	"cmd.bot.use",
	"cmd.rights.can",
]

# Admin: Server Admin (sgid=6) y Owner (sgid=9, ver scripts/ensure_owner.sh) pueden manejar
# el bot por completo desde el chat - renombrarlo (!bot name), moverlo (!bot move / !bot come),
# tocar settings, etc. La regla de "localhost = admin" de mas abajo NO alcanza para esto:
# solo aplica a llamadas a la WebAPI propia del bot (127.0.0.1:58913), nunca a mensajes de
# chat/ServerQuery que llegan por red, aunque sean del mismo owner.
[[rule]]
	groupid = [6, 9]
	useruid = []
	ip = [ "127.0.0.1", "::1", "::ffff:127.0.0.1" ]

	"+" = "*"

# Todo el mundo puede pedir/pausar/manejar musica y volumen (sin restriccion: sin
# groupid/useruid/ip esta regla matchea a cualquiera que se conecte, TS3 lo loguea como
# "Rule has no matcher and will always match" y es el comportamiento esperado).
[[rule]]
	"+" = [
		"cmd.play",
		"cmd.pause",
		"cmd.stop",
		"cmd.seek",
		"cmd.volume",
		"cmd.search.*",
		"cmd.list.*",
		"cmd.add",
		"cmd.clear",
		"cmd.previous",
		"cmd.next",
		"cmd.random.*",
		"cmd.repeat.*",
		"cmd.history.add",
		"cmd.history.from",
		"cmd.history.id",
		"cmd.history.last",
		"cmd.history.play",
		"cmd.history.till",
		"cmd.history.title",
	]
EOF
fi

exec /app/TS3AudioBot --non-interactive --hide-banner --stats-disabled "$@"
