#!/usr/bin/env bash
# Aprovisiona en Oracle Cloud (vía oci-cli) toda la infra de red + la VM para el TS3 server:
# VCN, internet gateway, ruta default, security list (SSH + puertos de TS3), subnet e instancia
# VM.Standard.A1.Flex. Idempotente: si un recurso ya existe (por display-name), lo reusa.
#
# Requisitos previos (una sola vez, manual):
#   - oci-cli instalado y en el PATH (ver https://docs.oracle.com/iaas/Content/API/SDKDocs/cliinstall.htm)
#   - ~/.oci/config con un API signing key ya configurado (Profile -> User settings -> API keys)
#
# Variables opcionales (todas tienen default):
#   COMPARTMENT_ID   default: la tenancy raíz (se lee de ~/.oci/config)
#   REGION           default: la de ~/.oci/config
#   DISPLAY_PREFIX   default: ts3
#   SHAPE_OCPUS      default: 1
#   SHAPE_MEMORY_GB  default: 6
#   SSH_PUBLIC_KEY   default: ~/.ssh/ts3_oracle.pub (se genera si no existe)
#   MAX_LAUNCH_ATTEMPTS   default: 5   (reintentos ante "Out of host capacity")
#   LAUNCH_RETRY_SECONDS  default: 60
set -euo pipefail

command -v oci >/dev/null 2>&1 || {
  echo "ERROR: oci-cli no está en el PATH. Instalalo primero (ver comentario arriba)." >&2
  exit 1
}

COMPARTMENT_ID="${COMPARTMENT_ID:-$(awk -F= '/^tenancy=/{print $2}' ~/.oci/config | head -1)}"
REGION="${REGION:-$(awk -F= '/^region=/{print $2}' ~/.oci/config | head -1)}"
PREFIX="${DISPLAY_PREFIX:-ts3}"
SHAPE_OCPUS="${SHAPE_OCPUS:-1}"
SHAPE_MEMORY_GB="${SHAPE_MEMORY_GB:-6}"
SSH_KEY_PATH="${SSH_PUBLIC_KEY:-$HOME/.ssh/ts3_oracle}"
MAX_LAUNCH_ATTEMPTS="${MAX_LAUNCH_ATTEMPTS:-5}"
LAUNCH_RETRY_SECONDS="${LAUNCH_RETRY_SECONDS:-60}"

[ -n "$COMPARTMENT_ID" ] || { echo "ERROR: no pude leer 'tenancy' de ~/.oci/config, seteá COMPARTMENT_ID a mano." >&2; exit 1; }
[ -n "$REGION" ] || { echo "ERROR: no pude leer 'region' de ~/.oci/config, seteá REGION a mano." >&2; exit 1; }

# oci-cli devuelve 401 NotAuthenticated de forma intermitente por un rato después de agregar
# una API key nueva (propagación desareja entre réplicas/servicios) — reintenta antes de fallar.
oci_r () {
  local attempt out code
  for attempt in $(seq 1 8); do
    if out=$(oci "$@" 2>&1); then
      echo "$out" | grep -vE "^(Warning: To increase security|Action completed\.|WARNING: This operation)"
      return 0
    fi
    code=$?
    if echo "$out" | grep -q "NotAuthenticated" && [ "$attempt" -lt 8 ]; then
      sleep 8
      continue
    fi
    echo "$out" | grep -vE "^(Warning: To increase security|Action completed\.|WARNING: This operation)" >&2
    return "$code"
  done
}

echo "==> Compartment: $COMPARTMENT_ID | Region: $REGION"

echo "==> VCN"
VCN_ID=$(oci_r network vcn list --compartment-id "$COMPARTMENT_ID" --display-name "${PREFIX}-vcn" --query "data[0].id" --raw-output)
if [ -z "$VCN_ID" ] || [ "$VCN_ID" = "null" ]; then
  VCN_ID=$(oci_r network vcn create \
    --compartment-id "$COMPARTMENT_ID" \
    --cidr-blocks '["10.0.0.0/16"]' \
    --display-name "${PREFIX}-vcn" \
    --dns-label "${PREFIX}vcn" \
    --wait-for-state AVAILABLE \
    --query "data.id" --raw-output)
  echo "    creada: $VCN_ID"
else
  echo "    ya existía: $VCN_ID"
fi

echo "==> Internet Gateway"
IGW_ID=$(oci_r network internet-gateway list --compartment-id "$COMPARTMENT_ID" --vcn-id "$VCN_ID" --query "data[0].id" --raw-output)
if [ -z "$IGW_ID" ] || [ "$IGW_ID" = "null" ]; then
  IGW_ID=$(oci_r network internet-gateway create \
    --compartment-id "$COMPARTMENT_ID" \
    --vcn-id "$VCN_ID" \
    --is-enabled true \
    --display-name "${PREFIX}-igw" \
    --wait-for-state AVAILABLE \
    --query "data.id" --raw-output)
  echo "    creado: $IGW_ID"
else
  echo "    ya existía: $IGW_ID"
fi

echo "==> Ruta default -> internet gateway"
RT_ID=$(oci_r network vcn get --vcn-id "$VCN_ID" --query "data.\"default-route-table-id\"" --raw-output)
oci_r network route-table update \
  --rt-id "$RT_ID" \
  --route-rules "[{\"destination\": \"0.0.0.0/0\", \"destinationType\": \"CIDR_BLOCK\", \"networkEntityId\": \"$IGW_ID\"}]" \
  --force >/dev/null
echo "    ok: $RT_ID"

echo "==> Security list (SSH 22, TS3 voz 9987/udp, ServerQuery 10011, transferencia 30033)"
SL_ID=$(oci_r network vcn get --vcn-id "$VCN_ID" --query "data.\"default-security-list-id\"" --raw-output)
oci_r network security-list update \
  --security-list-id "$SL_ID" \
  --ingress-security-rules '[
    {"protocol":"6","source":"0.0.0.0/0","sourceType":"CIDR_BLOCK","isStateless":false,"tcpOptions":{"destinationPortRange":{"min":22,"max":22}},"description":"SSH"},
    {"protocol":"17","source":"0.0.0.0/0","sourceType":"CIDR_BLOCK","isStateless":false,"udpOptions":{"destinationPortRange":{"min":9987,"max":9987}},"description":"TS3 voz"},
    {"protocol":"6","source":"0.0.0.0/0","sourceType":"CIDR_BLOCK","isStateless":false,"tcpOptions":{"destinationPortRange":{"min":10011,"max":10011}},"description":"TS3 ServerQuery/admin"},
    {"protocol":"6","source":"0.0.0.0/0","sourceType":"CIDR_BLOCK","isStateless":false,"tcpOptions":{"destinationPortRange":{"min":30033,"max":30033}},"description":"TS3 transferencia de archivos"}
  ]' \
  --force >/dev/null
echo "    ok: $SL_ID"

echo "==> Subnet"
SUBNET_ID=$(oci_r network subnet list --compartment-id "$COMPARTMENT_ID" --vcn-id "$VCN_ID" --display-name "${PREFIX}-subnet" --query "data[0].id" --raw-output)
if [ -z "$SUBNET_ID" ] || [ "$SUBNET_ID" = "null" ]; then
  SUBNET_ID=$(oci_r network subnet create \
    --compartment-id "$COMPARTMENT_ID" \
    --vcn-id "$VCN_ID" \
    --cidr-block 10.0.1.0/24 \
    --display-name "${PREFIX}-subnet" \
    --dns-label "${PREFIX}sub" \
    --prohibit-public-ip-on-vnic false \
    --wait-for-state AVAILABLE \
    --query "data.id" --raw-output)
  echo "    creada: $SUBNET_ID"
else
  echo "    ya existía: $SUBNET_ID"
fi

echo "==> SSH key para la instancia"
if [ ! -f "$SSH_KEY_PATH" ]; then
  ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -N "" -C "${PREFIX}-server-oracle" -q
  echo "    generada: $SSH_KEY_PATH"
else
  echo "    ya existía: $SSH_KEY_PATH"
fi

echo "==> Availability domain"
AD=$(oci_r iam availability-domain list --compartment-id "$COMPARTMENT_ID" --query "data[0].name" --raw-output)
echo "    $AD"

echo "==> Imagen Ubuntu 24.04 aarch64 (última disponible)"
IMAGE_ID=$(oci_r compute image list \
  --compartment-id "$COMPARTMENT_ID" \
  --operating-system "Canonical Ubuntu" \
  --operating-system-version "24.04" \
  --shape "VM.Standard.A1.Flex" \
  --sort-by TIMECREATED --sort-order DESC \
  --query "data[0].id" --raw-output)
echo "    $IMAGE_ID"

echo "==> Instancia ${PREFIX}-server (VM.Standard.A1.Flex, ${SHAPE_OCPUS} OCPU / ${SHAPE_MEMORY_GB}GB)"
EXISTING=$(oci_r compute instance list --compartment-id "$COMPARTMENT_ID" --display-name "${PREFIX}-server" --lifecycle-state RUNNING --query "data[0].id" --raw-output)
if [ -n "$EXISTING" ] && [ "$EXISTING" != "null" ]; then
  echo "    ya existe y está RUNNING: $EXISTING"
  INSTANCE_ID="$EXISTING"
else
  attempt=0
  INSTANCE_ID=""
  while [ -z "$INSTANCE_ID" ] && [ "$attempt" -lt "$MAX_LAUNCH_ATTEMPTS" ]; do
    attempt=$((attempt+1))
    if out=$(oci_r compute instance launch \
      --compartment-id "$COMPARTMENT_ID" \
      --availability-domain "$AD" \
      --display-name "${PREFIX}-server" \
      --shape VM.Standard.A1.Flex \
      --shape-config "{\"ocpus\": $SHAPE_OCPUS, \"memoryInGBs\": $SHAPE_MEMORY_GB}" \
      --subnet-id "$SUBNET_ID" \
      --image-id "$IMAGE_ID" \
      --assign-public-ip true \
      --ssh-authorized-keys-file "${SSH_KEY_PATH}.pub" \
      --query "data.id" --raw-output); then
      INSTANCE_ID="$out"
    elif echo "$out" | grep -qi "Out of host capacity"; then
      echo "    intento $attempt: sin capacidad (Always Free A1.Flex es muy pedido), reintento en ${LAUNCH_RETRY_SECONDS}s..."
      sleep "$LAUNCH_RETRY_SECONDS"
    else
      echo "$out" >&2
      exit 1
    fi
  done
  [ -n "$INSTANCE_ID" ] || { echo "ERROR: se agotaron los $MAX_LAUNCH_ATTEMPTS intentos por falta de capacidad. Reintentá más tarde o probá VM.Standard.E2.1.Micro." >&2; exit 1; }
  echo "    lanzada: $INSTANCE_ID"
fi

echo "==> Esperando a que la instancia esté RUNNING..."
oci_r compute instance get --instance-id "$INSTANCE_ID" --wait-for-state RUNNING >/dev/null
PUBLIC_IP=$(oci_r compute instance list-vnics --instance-id "$INSTANCE_ID" --query "data[0].\"public-ip\"" --raw-output)

echo ""
echo "==> Listo. IP pública: $PUBLIC_IP"
echo "    Conectate con: ssh -i $SSH_KEY_PATH ubuntu@$PUBLIC_IP"
echo "    Y corré: git clone https://github.com/guidoenr/ts3.git && cd ts3 && ./scripts/bootstrap.sh"
