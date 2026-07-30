# TS3 en Oracle Cloud (Always Free) con Docker

Server de TeamSpeak 3 clásico corriendo en una VM gratuita de Oracle Cloud Infrastructure (OCI), con Docker Compose usando la imagen oficial `teamspeak` de Docker Hub.

## Arquitectura

- **Cloud**: Oracle Cloud Infrastructure, tier Always Free.
- **Región**: Chile Central - Santiago (`sa-santiago-1`). Oracle no tiene región en Argentina; Santiago es la más cercana geográficamente a Buenos Aires.
- **VM**: `VM.Standard.A1.Flex` (ARM Ampere, Always Free — hasta 4 OCPU / 24 GB RAM totales entre todas tus instancias A1).
- **App**: imagen oficial `teamspeak` (Docker Official Image), corre nativo en arm64.
- **Puertos**: `9987/udp` (voz), `10011/tcp` (ServerQuery/admin), `30033/tcp` (transferencia de archivos).

## ⚠️ Antes de crear la cuenta de Oracle

1. **La "home region" se elige en el signup y después es prácticamente imposible cambiarla** (requiere ticket de soporte o cuenta nueva). Elegí **Chile Central (Santiago)** o **Chile West (Valparaíso)** al registrarte.
2. Piden **tarjeta de crédito** para verificar identidad, aunque el tier Always Free no cobra nada mientras te mantengas dentro de los límites gratuitos.
3. Las instancias ARM `A1.Flex` gratuitas son muy pedidas y **es común el error "Out of host capacity"** al crearlas. Santiago (`sa-santiago-1`) tiene un solo Availability Domain, así que no hay AD alternativo para rotar — la única opción es reintentar (`scripts/provision_oracle.sh` ya reintenta solo) o probar en otro horario. Como plan B existe el shape `VM.Standard.E2.1.Micro` (AMD, siempre disponible, pero solo 1 GB RAM — alcanza de sobra para TS3 solo, que es muy liviano).

## Automatización con OCI CLI (opcional)

En vez de clickear toda la consola web (Pasos 1 a 6), se puede automatizar todo desde terminal con [oci-cli](https://docs.oracle.com/iaas/Content/API/SDKDocs/cliinstall.htm):

1. Una sola vez, a mano en la consola: generar un API Signing Key (**Profile → User settings → API Keys → Add API Key**) y armar `~/.oci/config` con `user`, `fingerprint`, `tenancy`, `region` y `key_file`.
2. `./scripts/provision_oracle.sh` — crea VCN, internet gateway, ruta, security list, subnet, par de claves SSH (`~/.ssh/ts3_oracle`) y la instancia (reintentando solo ante "Out of host capacity"). Es idempotente, se puede volver a correr sin duplicar recursos.
3. `./scripts/remote_deploy.sh <PUBLIC_IP>` — espera a que SSH esté listo y corre el deploy completo (clone + `bootstrap.sh`) en la VM ya creada.

## Paso 1 — Crear la cuenta de Oracle Cloud

Andá a [oracle.com/cloud/free](https://www.oracle.com/cloud/free/) y registrate eligiendo **Chile Central (Santiago)** como home region.

## Paso 2 — Crear la VM

En la consola de OCI: **Compute → Instances → Create Instance**.

- **Name**: `ts3-server`
- **Image**: Ubuntu 24.04 (Canonical) — más simple de administrar que Oracle Linux para este caso.
- **Shape**: Change Shape → Ampere → `VM.Standard.A1.Flex` → 1 OCPU / 6 GB RAM alcanza sobrado para TS3.
- **Networking**: dejá que cree una VCN nueva por default.
- **SSH keys**: generá un par nuevo y **descargá la clave privada** (la vas a necesitar para conectarte).
- Create, y esperá a que el estado pase a "Running". Anotá la **Public IP**.

## Paso 3 — Abrir los puertos

### 3a. Security List / Network Security Group (a nivel VCN, en la consola de Oracle)

Andá a la VCN de tu instancia → **Security Lists** (o el NSG que hayas elegido) → **Add Ingress Rules**, y agregá:

| Source CIDR | Protocolo | Puerto destino |
|---|---|---|
| 0.0.0.0/0 | UDP | 9987 |
| 0.0.0.0/0 | TCP | 30033 |
| 0.0.0.0/0 | TCP | 10011 |

> **Seguridad**: 10011 es la interfaz de administración (ServerQuery). Si tenés IP fija, considerá restringir esa regla solo a tu IP en vez de `0.0.0.0/0`.

### 3b. Firewall del sistema operativo (dentro de la VM)

Las imágenes Ubuntu de OCI traen **iptables con política restrictiva por default** (UFW aparece "inactive" pero igual bloquea, porque el filtrado real está en `/etc/iptables/rules.v4`). El script `scripts/bootstrap.sh` de este repo ya se encarga de esto, pero si querés hacerlo a mano:

```bash
sudo iptables -I INPUT -p udp --dport 9987 -j ACCEPT
sudo iptables -I INPUT -p tcp --dport 10011 -j ACCEPT
sudo iptables -I INPUT -p tcp --dport 30033 -j ACCEPT
sudo netfilter-persistent save
```

## Paso 4 — Conectarte por SSH y levantar todo

```bash
ssh -i /ruta/a/tu/clave_privada ubuntu@<PUBLIC_IP>
git clone https://github.com/guidoenr/ts3.git
cd ts3
./scripts/bootstrap.sh
```

El script instala Docker + Compose, abre los puertos en iptables, instala un keepalive anti-reclamo (ver sección "Costos y disponibilidad" más abajo), y levanta el `docker-compose.yml`.

## Paso 5 — Guardar las credenciales de admin

**Importante**: la primera vez que arranca, el server genera la contraseña de `serveradmin` y el *privilege key* (token para tomar admin del virtual server 1) y los imprime **una sola vez** en los logs. Si los perdés, no hay forma de recuperarlos sin borrar el volumen (y con eso perdés toda la configuración del server).

```bash
sudo docker compose logs teamspeak | grep -E 'loginname|token='
```

Guardá ese login/password y el token en un lugar seguro (gestor de contraseñas).

## Paso 6 — Conectarte con el cliente

Desde el cliente TeamSpeak 3 clásico (o TeamSpeak 6, ver más abajo), conectate a `<PUBLIC_IP>` con la password del server (ver sección siguiente). El *privilege key* del Paso 5 sigue funcionando como respaldo por si algo de la configuración automática falla, pero con la config actual no debería hacer falta: todo el que entra ya queda con admin.

## Configuración automática del server

`bootstrap.sh` levanta el container, y a continuación `scripts/configure_server.sh` se conecta por **ServerQuery** (puerto 10011, localhost) y configura el virtual server la primera vez que arranca — nombre, password, canales y permisos — sin que haya que tocar nada a mano. Esto corre solo como parte de `remote_deploy.sh`; si el server ya arrancó antes (ya tiene historial), el script no encuentra credenciales nuevas en los logs y no hace nada (evita pisar configuración existente).

Los valores salen de variables de entorno (poné un `.env` antes del primer deploy si querés cambiarlos — ver `.env.example`):

| Variable | Default |
|---|---|
| `TS3_SERVER_NAME` | `el SERVER del guidoti` |
| `TS3_SERVER_PASSWORD` | `asdf` |
| `TS3_CHANNEL_1` / `_2` / `_3` | `LOBBYS`, `MIX10-Team1`, `MIX10-Team2` |

**⚠️ Todo el que se conecta queda con el grupo "Server Admin" por default** (se cambia `virtualserver_default_server_group` vía ServerQuery). Es intencional — así lo pidió quien lo armó, para no andar gestionando permisos en un server chico de amigos — pero significa que cualquiera con la password puede kickear/banear a otros, borrar canales o cambiar la configuración. Si en algún momento eso deja de tener sentido (server más grande, gente que no conocés), lo primero que hay que tocar es esa property.

## Mantenimiento

- **Logs**: `sudo docker compose logs -f teamspeak`
- **Reiniciar**: `sudo docker compose restart teamspeak`
- **Actualizar imagen**: `sudo docker compose pull && sudo docker compose up -d`
- **Backup**: el volumen `ts3-data` vive en `/var/lib/docker/volumes/ts3-data/_data`. Conviene copiarlo periódicamente a otro lado (ej. `rsync` a tu máquina, o antes de cualquier actualización mayor).

## Costos y disponibilidad

- **Costo**: los recursos "Always Free" (A1.Flex hasta 4 OCPU/24GB, 200GB de storage, 10TB/mes de salida) son gratis de por vida mientras te mantengas dentro de esos límites — no es un trial de 30 días. El tráfico de voz de TS3 es insignificante comparado con el límite de salida.
- **Reclamo por inactividad**: Oracle apaga (no borra) instancias A1.Flex Always Free si durante 7 días el percentil 95 de uso de CPU, red y memoria está simultáneamente por debajo del 20%. Si el server queda una semana sin uso real, corre riesgo de que lo paren solo. `bootstrap.sh` instala `ts3-keepalive.service` (systemd + `stress-ng` a baja prioridad, ~25% de un core) para que el uso de CPU nunca caiga del umbral y la instancia no se considere idle. Es intencional que quede corriendo siempre — no es un bug ni un proceso descolgado.
- Ver `oci compute instance action --action START` (o la consola) si alguna vez la ves parada: es reversible, no se pierde nada.

## Troubleshooting

- **"Out of host capacity" al crear la VM A1.Flex**: reintentá en otro AD de la misma región, o probá en otro momento del día. Alternativa: `VM.Standard.E2.1.Micro` (AMD, siempre disponible).
- **No conecta desde afuera pero desde la VM sí responde**: revisá en este orden — Security List/NSG (paso 3a) → iptables en la VM (paso 3b) → que el contenedor esté `Up` (`docker compose ps`).
- **Perdiste el privilege key**: no se puede recuperar; si es un server nuevo sin uso real, lo más simple es `docker compose down -v` (borra el volumen) y arrancar de cero.
