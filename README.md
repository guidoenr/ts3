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
3. Las instancias ARM `A1.Flex` gratuitas son muy pedidas y **es común el error "Out of host capacity"** al crearlas. Si te pasa: probá en otro Availability Domain (AD) dentro de la misma región, o reintentá en otro horario. Como plan B existe el shape `VM.Standard.E2.1.Micro` (AMD, siempre disponible, pero solo 1 GB RAM — alcanza de sobra para TS3 solo, que es muy liviano).

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
git clone <URL_DE_TU_REPO_EN_GITHUB> ts3
cd ts3
./scripts/bootstrap.sh
```

El script instala Docker + Compose, abre los puertos en iptables, y levanta el `docker-compose.yml`.

## Paso 5 — Guardar las credenciales de admin

**Importante**: la primera vez que arranca, el server genera la contraseña de `serveradmin` y el *privilege key* (token para tomar admin del virtual server 1) y los imprime **una sola vez** en los logs. Si los perdés, no hay forma de recuperarlos sin borrar el volumen (y con eso perdés toda la configuración del server).

```bash
sudo docker compose logs teamspeak | grep -E 'loginname|token='
```

Guardá ese login/password y el token en un lugar seguro (gestor de contraseñas).

## Paso 6 — Conectarte con el cliente

Desde el cliente TeamSpeak 3 clásico, conectate a `<PUBLIC_IP>` (puerto 9987 por default, no hace falta especificarlo). Para tomar privilegios de admin: **Permissions → Use Privilege Key** y pegá el token del paso anterior.

## Mantenimiento

- **Logs**: `sudo docker compose logs -f teamspeak`
- **Reiniciar**: `sudo docker compose restart teamspeak`
- **Actualizar imagen**: `sudo docker compose pull && sudo docker compose up -d`
- **Backup**: el volumen `ts3-data` vive en `/var/lib/docker/volumes/ts3-data/_data`. Conviene copiarlo periódicamente a otro lado (ej. `rsync` a tu máquina, o antes de cualquier actualización mayor).

## Troubleshooting

- **"Out of host capacity" al crear la VM A1.Flex**: reintentá en otro AD de la misma región, o probá en otro momento del día. Alternativa: `VM.Standard.E2.1.Micro` (AMD, siempre disponible).
- **No conecta desde afuera pero desde la VM sí responde**: revisá en este orden — Security List/NSG (paso 3a) → iptables en la VM (paso 3b) → que el contenedor esté `Up` (`docker compose ps`).
- **Perdiste el privilege key**: no se puede recuperar; si es un server nuevo sin uso real, lo más simple es `docker compose down -v` (borra el volumen) y arrancar de cero.
