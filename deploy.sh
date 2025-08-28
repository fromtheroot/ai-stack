#!/usr/bin/env bash
set -euo pipefail

# Simple interactive deployment script for the self-hosted AI starter kit

show_usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --local    Deploy for local testing (no Traefik, direct port access)
  --help     Show this help message

Examples:
  $0          # Production deployment with Traefik and HTTPS
  $0 --local  # Local testing deployment
EOF
}

LOCAL_MODE=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --local)
      LOCAL_MODE=true
      shift
      ;;
    --help|-h)
      show_usage
      exit 0
      ;;
    *)
      err "Unknown option: $1"
      show_usage
      exit 1
      ;;
  esac
done

bold() { printf "\033[1m%s\033[0m\n" "$*"; }
note() { printf "[+] %s\n" "$*"; }
warn() { printf "[!] %s\n" "$*"; }
err() { printf "[x] %s\n" "$*" 1>&2; }

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    err "Required command '$1' not found. Please install it and re-run."
    exit 1
  fi
}

gen_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 48 | tr -d '\n'
  else
    head -c 48 /dev/urandom | base64 | tr -d '\n'
  fi
}

read_default() {
  local prompt="$1"; shift
  local default_val="$1"; shift
  local __resultvar="$1"; shift || true
  local input
  read -r -p "$prompt [$default_val]: " input || true
  if [ -z "${input:-}" ]; then input="$default_val"; fi
  printf -v "$__resultvar" '%s' "$input"
}

# 0) Checks
require_cmd docker
if ! docker compose version >/dev/null 2>&1; then
  err "Docker Compose plugin not found. Install Docker Compose plugin and try again."
  exit 1
fi

bold "Self-hosted AI Starter Kit - Deployment"

if [[ "$LOCAL_MODE" == "true" ]]; then
  note "Local testing mode enabled (no Traefik/HTTPS)"
fi

# 1) Gather inputs
if [[ "$LOCAL_MODE" == "true" ]]; then
  default_domain="localhost"
  default_email="admin@localhost"
else
  default_domain="n8n.example.com"
  default_email="admin@example.com"
fi

default_db_user="n8n"
default_db_name="n8n"
default_db_pass="$(gen_secret | cut -c1-24)"

if [[ "$LOCAL_MODE" == "true" ]]; then
  DOMAIN="localhost"
  EMAIL="admin@localhost"
  note "Using localhost for local testing"
else
  read_default "Enter your domain for n8n (N8N_HOST)" "$default_domain" DOMAIN
  DOMAIN="${DOMAIN#http://}"
  DOMAIN="${DOMAIN#https://}"
  DOMAIN="${DOMAIN%/}"

  read_default "Enter email for Let's Encrypt (LETSENCRYPT_EMAIL)" "$default_email" EMAIL
fi

read_default "PostgreSQL user (POSTGRES_USER)" "$default_db_user" DB_USER
read_default "PostgreSQL password (POSTGRES_PASSWORD)" "$default_db_pass" DB_PASS
read_default "PostgreSQL database (POSTGRES_DB)" "$default_db_name" DB_NAME

echo
bold "Service selection"
read_default "Enable Qdrant? (y/N)" "N" ENABLE_QDRANT
read_default "Enable Ollama? (y/N)" "N" ENABLE_OLLAMA

PROFILE="cpu"
if [[ "${ENABLE_OLLAMA^^}" == "Y" ]]; then
  echo
  bold "Select runtime profile"
  read_default "Profile (cpu|gpu-nvidia|gpu-amd)" "cpu" PROFILE
  case "$PROFILE" in
    cpu|gpu-nvidia|gpu-amd) ;;
    *) warn "Unknown profile '$PROFILE', defaulting to cpu"; PROFILE="cpu" ;;
  esac
fi

# Optional external Ollama host override
read_default "Use external Ollama host instead of container? (y/N)" "N" EXT_OLLAMA
OLLAMA_HOST_VAR=""
OLLAMA_PORT_VAR=""
if [[ "${EXT_OLLAMA^^}" == "Y" ]]; then
  read_default "Enter external Ollama host:port" "host.docker.internal:11434" EXT_OLLAMA_HOST
  OLLAMA_HOST_VAR="\nOLLAMA_HOST=${EXT_OLLAMA_HOST}"
  if [[ "$LOCAL_MODE" == "true" ]]; then
    note "External Ollama detected - will not start Ollama container"
  fi
fi

# 2) Prepare secrets and .env
if [ -f .env ]; then
  read_default ".env already exists. Overwrite? (y/N)" "N" OVERWRITE_ENV
  if [[ "${OVERWRITE_ENV^^}" != "Y" ]]; then
    err "Refusing to overwrite existing .env. Aborting."
    exit 1
  fi
fi

ENC_KEY="$(gen_secret)"
JWT_SECRET="$(gen_secret)"

if [[ "$LOCAL_MODE" == "true" ]]; then
  # Local mode: HTTP, no proxy, no Let's Encrypt
  cat > .env <<EOF
POSTGRES_USER=${DB_USER}
POSTGRES_PASSWORD=${DB_PASS}
POSTGRES_DB=${DB_NAME}

N8N_ENCRYPTION_KEY=${ENC_KEY}
N8N_USER_MANAGEMENT_JWT_SECRET=${JWT_SECRET}
N8N_DEFAULT_BINARY_DATA_MODE=filesystem

N8N_HOST=${DOMAIN}
N8N_PROTOCOL=http
N8N_PORT=5678
N8N_PATH=/
N8N_PROXY_HOPS=0
WEBHOOK_URL=http://${DOMAIN}:5678/
LETSENCRYPT_EMAIL=${EMAIL}${OLLAMA_HOST_VAR}
EOF
else
  # Production mode: HTTPS, Traefik, Let's Encrypt
  cat > .env <<EOF
POSTGRES_USER=${DB_USER}
POSTGRES_PASSWORD=${DB_PASS}
POSTGRES_DB=${DB_NAME}

N8N_ENCRYPTION_KEY=${ENC_KEY}
N8N_USER_MANAGEMENT_JWT_SECRET=${JWT_SECRET}
N8N_DEFAULT_BINARY_DATA_MODE=filesystem

N8N_HOST=${DOMAIN}
N8N_PROTOCOL=https
N8N_PORT=5678
N8N_PATH=/
N8N_PROXY_HOPS=1
WEBHOOK_URL=https://${DOMAIN}/
LETSENCRYPT_EMAIL=${EMAIL}${OLLAMA_HOST_VAR}
EOF
fi

note ".env written"

# 3) Prepare files and folders
if [[ "$LOCAL_MODE" == "true" ]]; then
  # Local mode: no acme.json needed
  note "Skipping acme.json for local mode"
else
  touch acme.json
  chmod 600 acme.json || true
fi

mkdir -p shared

# 4) Build compose command
SERVICES=(postgres n8n-import n8n)
if [[ "$LOCAL_MODE" == "false" ]]; then
  SERVICES+=(traefik)
fi

if [[ "${ENABLE_QDRANT^^}" == "Y" ]]; then
  SERVICES+=(qdrant)
fi
if [[ "${ENABLE_OLLAMA^^}" == "Y" && "${EXT_OLLAMA^^}" != "Y" ]]; then
  case "$PROFILE" in
    cpu)
      SERVICES+=(ollama-cpu ollama-pull-llama-cpu)
      ;;
    gpu-nvidia)
      SERVICES+=(ollama-gpu ollama-pull-llama-gpu)
      ;;
    gpu-amd)
      SERVICES+=(ollama-gpu-amd ollama-pull-llama-gpu-amd)
      ;;
  esac
fi

bold "Starting services: ${SERVICES[*]} (profile: $PROFILE)"

if [[ "$LOCAL_MODE" == "true" ]]; then
  # Create local override to expose ports
  cat > docker-compose.local.yml <<EOF
services:
  n8n:
    ports:
      - "5678:5678"
EOF

  if [[ "${ENABLE_QDRANT^^}" == "Y" ]]; then
    cat >> docker-compose.local.yml <<EOF
  qdrant:
    ports:
      - "6333:6333"
EOF
  fi

  if [[ "${ENABLE_OLLAMA^^}" == "Y" && "${EXT_OLLAMA^^}" != "Y" ]]; then
    case "$PROFILE" in
      cpu)
        cat >> docker-compose.local.yml <<EOF
  ollama-cpu:
    ports:
      - "11434:11434"
EOF
        ;;
      gpu-nvidia)
        cat >> docker-compose.local.yml <<EOF
  ollama-gpu:
    ports:
      - "11434:11434"
EOF
        ;;
      gpu-amd)
        cat >> docker-compose.local.yml <<EOF
  ollama-gpu-amd:
    ports:
      - "11434:11434"
EOF
        ;;
    esac
  fi

  note "Created docker-compose.local.yml for port exposure"
  docker compose -f docker-compose.yml -f docker-compose.local.yml --profile "$PROFILE" up -d "${SERVICES[@]}"
else
  docker compose --profile "$PROFILE" up -d "${SERVICES[@]}"
fi

echo
bold "Done!"

if [[ "$LOCAL_MODE" == "true" ]]; then
  note "Local testing setup complete!"
  note "Check logs:   docker compose logs -f n8n | cat"
  note "Open n8n:     http://localhost:5678"
  if [[ "${ENABLE_QDRANT^^}" == "Y" ]]; then
    note "Open Qdrant:  http://localhost:6333"
  fi
  if [[ "${ENABLE_OLLAMA^^}" == "Y" && "${EXT_OLLAMA^^}" != "Y" ]]; then
    note "Open Ollama:  http://localhost:11434"
  fi
else
  note "Traefik and n8n are starting. It may take ~1-3 minutes for TLS to be issued."
  note "Check logs:   docker compose logs -f traefik n8n | cat"
  note "Open n8n:     https://${DOMAIN}"
fi


