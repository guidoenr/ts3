# TS3AudioBot corre "develop" porque es la unica rama con builds activos: "master" quedo
# congelada en 0.12.2 (2021, dotnet core 3.1 EOL). El nightly server de Splamy sigue publicando
# builds de "develop" (0.13.x, .NET 6) regularmente - ver https://splamy.de/Nightly#ts3ab.
FROM debian:bookworm-slim

# libopus-dev (no solo libopus0) porque el bot busca la lib sin sufijo de version
# ("libopus.so", no "libopus.so.0") - solo el paquete -dev deja ese symlink.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl unzip libopus-dev ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# yt-dlp necesita un runtime de JS para resolver algunos de los desafios que pone YouTube
# (firma de "n", etc) - sin esto tira "No supported JavaScript runtime could be found" y
# encima ni intenta el intercambio de token con el pot-provider (queda en LOGIN_REQUIRED
# directo). deno es liviano y yt-dlp lo detecta solo si esta en el PATH.
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
      amd64) denoarch=x86_64 ;; \
      arm64) denoarch=aarch64 ;; \
      *) echo "Arquitectura no soportada para deno: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/deno.zip "https://github.com/denoland/deno/releases/latest/download/deno-${denoarch}-unknown-linux-gnu.zip"; \
    unzip -o /tmp/deno.zip -d /usr/local/bin; \
    rm /tmp/deno.zip; \
    chmod +x /usr/local/bin/deno

# yt-dlp de apt (Debian bookworm) esta anclado a 2023.03.04: YouTube cambia seguido su API
# interna y una version vieja falla todo el tiempo ("Precondition check failed", HTTP 400).
# Bajamos el binario standalone mas nuevo directo de GitHub en vez de usar el paquete de apt.
RUN curl -fsSL -o /usr/local/bin/yt-dlp https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_linux \
    && chmod +x /usr/local/bin/yt-dlp

# YouTube bloquea por reputacion de IP a los datacenters (Oracle/AWS/GCP/etc, no es algo
# nuestro): sin esto, yt-dlp tira "Sign in to confirm you're not a bot" siempre, cookies
# incluidas. El plugin bgutil-ytdlp-pot-provider genera los tokens que YouTube pide,
# hablando con el servicio "pot-provider" del compose (127.0.0.1:4416, misma red que
# comparten teamspeak/audiobot) - no depende de ninguna cuenta ni cookies.
RUN mkdir -p /root/.yt-dlp/plugins \
    && curl -fsSL -o /root/.yt-dlp/plugins/bgutil-ytdlp-pot-provider.zip \
       https://github.com/Brainicism/bgutil-ytdlp-pot-provider/releases/download/2.0.0/bgutil-ytdlp-pot-provider.zip

WORKDIR /app
ARG TS3AB_CHANNEL=develop
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
      amd64) plat=linux_x64 ;; \
      arm64) plat=linux_arm64 ;; \
      armhf) plat=linux_arm ;; \
      *) echo "Arquitectura no soportada: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://splamy.de/api/nightly/projects/ts3ab/${TS3AB_CHANNEL}_${plat}/download" -o ts3ab.tar.gz; \
    tar -xzf ts3ab.tar.gz; \
    rm ts3ab.tar.gz; \
    chmod +x TS3AudioBot

COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

WORKDIR /data
ENTRYPOINT ["/app/entrypoint.sh"]
