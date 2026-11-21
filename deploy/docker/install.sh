#!/usr/bin/env bash
# One-command Docker install for OpenJarvis (API server + web UI + Ollama).
#
#   deploy/docker/install.sh [--gpu cpu|nvidia|rocm] [--model NAME]
#                            [--port N] [--bind ADDR | --lan]
#
# Safe to re-run: it keeps an existing .env (and its API key), rebuilds the
# image from the current checkout and recreates the containers. That makes
# `git pull && deploy/docker/install.sh` the update path as well.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ENV_FILE=".env"
HEALTH_TIMEOUT="${OPENJARVIS_HEALTH_TIMEOUT:-600}"
MIN_COMPOSE_MAJOR=2
MIN_COMPOSE_MINOR=24 # env_file `required: false` needs Compose 2.24+

GPU=""
MODEL=""
PORT=""
BIND=""

if [ -t 1 ]; then
    BOLD=$'\033[1m' DIM=$'\033[2m' RED=$'\033[31m' GREEN=$'\033[32m' YELLOW=$'\033[33m' RESET=$'\033[0m'
else
    BOLD="" DIM="" RED="" GREEN="" YELLOW="" RESET=""
fi

say() { printf '%s==>%s %s\n' "$BOLD" "$RESET" "$*"; }
warn() { printf '%swarning:%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die() {
    printf '%serror:%s %s\n' "$RED" "$RESET" "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Install and start OpenJarvis with Docker Compose.

Usage: deploy/docker/install.sh [options]

Options:
  --gpu cpu|nvidia|rocm   Image variant (default: keep the previous choice, else cpu).
                          nvidia needs the NVIDIA Container Toolkit.
  --model NAME            Ollama model to serve, e.g. qwen3.5:9b (default: qwen3.5:2b).
  --port N                Host port for the web UI + API (default: 1337).
  --bind ADDR             Host interface to publish on (default: 127.0.0.1).
  --lan                   Shorthand for --bind 0.0.0.0 (reachable from your network).
  -h, --help              Show this help.

Choices are stored in deploy/docker/.env, so later `docker compose` commands
run from deploy/docker/ use the same settings.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
    --gpu)
        GPU="${2:-}"
        shift 2 || die "--gpu needs a value"
        ;;
    --gpu=*)
        GPU="${1#*=}"
        shift
        ;;
    --model)
        MODEL="${2:-}"
        shift 2 || die "--model needs a value"
        ;;
    --model=*)
        MODEL="${1#*=}"
        shift
        ;;
    --port)
        PORT="${2:-}"
        shift 2 || die "--port needs a value"
        ;;
    --port=*)
        PORT="${1#*=}"
        shift
        ;;
    --bind)
        BIND="${2:-}"
        shift 2 || die "--bind needs a value"
        ;;
    --bind=*)
        BIND="${1#*=}"
        shift
        ;;
    --lan)
        BIND="0.0.0.0"
        shift
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        die "unknown option: $1"
        ;;
    esac
done

case "$GPU" in
"" | cpu | nvidia | rocm) ;;
*) die "--gpu must be cpu, nvidia or rocm (got '$GPU')" ;;
esac
if [ -n "$PORT" ]; then
    case "$PORT" in
    *[!0-9]*) die "--port must be a number (got '$PORT')" ;;
    esac
    { [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; } || die "--port must be 1-65535"
fi
case "$MODEL" in
*[[:space:]]*) die "--model must be a single model name" ;;
esac

# --- .env helpers -----------------------------------------------------------

# Print the value of KEY from .env (last uncommented assignment wins), with
# surrounding quotes removed the way Compose does.
env_get() {
    [ -f "$ENV_FILE" ] || return 0
    awk -v key="$1" '
        index($0, key "=") == 1 { val = substr($0, length(key) + 2) }
        END {
            if (val ~ /^".*"$/ || val ~ /^\047.*\047$/) val = substr(val, 2, length(val) - 2)
            if (val != "") print val
        }
    ' "$ENV_FILE"
}

# Set KEY=VALUE in .env: replaces an existing (or commented-out `#KEY=`) line,
# otherwise appends. Values are passed via the environment so no character in
# them is interpreted by awk or sed.
env_set() {
    local tmp
    tmp="$(mktemp "${ENV_FILE}.XXXXXX")"
    ENV_KEY="$1" ENV_VAL="$2" awk '
        BEGIN { key = ENVIRON["ENV_KEY"]; line = key "=" ENVIRON["ENV_VAL"] }
        !done && (index($0, key "=") == 1 || index($0, "#" key "=") == 1) {
            print line; done = 1; next
        }
        index($0, key "=") == 1 { next }  # drop duplicate assignments
        { print }
        END { if (!done) print line }
    ' "$ENV_FILE" >"$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$ENV_FILE"
}

generate_key() {
    local hex
    if command -v openssl >/dev/null 2>&1; then
        hex="$(openssl rand -hex 32)"
    else
        hex="$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
    fi
    [ "${#hex}" -eq 64 ] || die "could not generate a random API key"
    printf 'oj_sk_%s' "$hex"
}

# --- Preflight --------------------------------------------------------------

say "Checking Docker"
command -v docker >/dev/null 2>&1 ||
    die "Docker is not installed. Get it from https://docs.docker.com/get-docker/"

if ! docker_err="$(docker info 2>&1 >/dev/null)"; then
    case "$docker_err" in
    *"permission denied"*)
        die "no permission to use Docker. Add yourself to the 'docker' group (then log out and back in) or run this script with sudo."
        ;;
    *) die "the Docker daemon is not reachable. Start Docker and try again. ($docker_err)" ;;
    esac
fi

docker compose version >/dev/null 2>&1 ||
    die "the Docker Compose v2 plugin is missing ('docker compose'). See https://docs.docker.com/compose/install/"

compose_version="$(docker compose version --short 2>/dev/null | sed 's/^v//')"
compose_major="${compose_version%%.*}"
compose_minor="${compose_version#*.}"
compose_minor="${compose_minor%%.*}"
case "$compose_major$compose_minor" in
*[!0-9]* | "")
    warn "could not parse the Docker Compose version ('$compose_version'); continuing"
    ;;
*)
    if [ "$compose_major" -lt "$MIN_COMPOSE_MAJOR" ] ||
        { [ "$compose_major" -eq "$MIN_COMPOSE_MAJOR" ] && [ "$compose_minor" -lt "$MIN_COMPOSE_MINOR" ]; }; then
        die "Docker Compose $compose_version is too old; $MIN_COMPOSE_MAJOR.$MIN_COMPOSE_MINOR or newer is required"
    fi
    ;;
esac

if [ "$GPU" = "nvidia" ] && ! docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q nvidia; then
    warn "Docker reports no 'nvidia' runtime; install the NVIDIA Container Toolkit if GPU startup fails."
fi

# --- Configuration ----------------------------------------------------------

if [ ! -f "$ENV_FILE" ]; then
    say "Creating $SCRIPT_DIR/$ENV_FILE"
    cp .env.example "$ENV_FILE"
fi
chmod 600 "$ENV_FILE"

if [ -z "$(env_get OPENJARVIS_API_KEY)" ]; then
    say "Generating an API key"
    env_set OPENJARVIS_API_KEY "$(generate_key)"
fi
[ -n "$MODEL" ] && env_set OPENJARVIS_MODEL "$MODEL"
[ -n "$PORT" ] && env_set OPENJARVIS_PORT "$PORT"
[ -n "$BIND" ] && env_set OPENJARVIS_BIND "$BIND"

case "$GPU" in
nvidia) env_set COMPOSE_FILE "docker-compose.yml:docker-compose.gpu.nvidia.yml" ;;
rocm) env_set COMPOSE_FILE "docker-compose.yml:docker-compose.gpu.rocm.yml" ;;
cpu) env_set COMPOSE_FILE "docker-compose.yml" ;;
"")
    if [ -z "$(env_get COMPOSE_FILE)" ] && command -v nvidia-smi >/dev/null 2>&1 &&
        nvidia-smi -L >/dev/null 2>&1; then
        printf '%sAn NVIDIA GPU was detected; re-run with --gpu nvidia to use it.%s\n' "$DIM" "$RESET"
    fi
    ;;
esac

# Compose reads COMPOSE_FILE from .env itself; export it as well so the
# commands below honour a choice that was just written.
compose_file="$(env_get COMPOSE_FILE)"
if [ -n "$compose_file" ]; then
    export COMPOSE_FILE="$compose_file"
else
    unset COMPOSE_FILE
fi

api_key="$(env_get OPENJARVIS_API_KEY)"
model="$(env_get OPENJARVIS_MODEL)"
model="${model:-qwen3.5:2b}"
port="$(env_get OPENJARVIS_PORT)"
port="${port:-1337}"
bind="$(env_get OPENJARVIS_BIND)"
bind="${bind:-127.0.0.1}"

# --- Build and start --------------------------------------------------------

say "Building the OpenJarvis image (the first build takes several minutes)"
docker compose build jarvis

say "Starting Ollama"
docker compose up -d --wait ollama

say "Making sure the model is available: $model"
docker compose run --rm ollama-pull

say "Starting OpenJarvis"
docker compose up -d --remove-orphans

say "Waiting for the server to become healthy (up to ${HEALTH_TIMEOUT}s)"
deadline=$((SECONDS + HEALTH_TIMEOUT))
status="starting"
while [ "$SECONDS" -lt "$deadline" ]; do
    cid="$(docker compose ps -q jarvis 2>/dev/null || true)"
    if [ -n "$cid" ]; then
        status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid" 2>/dev/null || echo unknown)"
        restarts="$(docker inspect -f '{{.RestartCount}}' "$cid" 2>/dev/null || echo 0)"
        [ "$status" = "healthy" ] && break
        if [ "$status" = "unhealthy" ] || [ "${restarts:-0}" -ge 3 ]; then
            break
        fi
    fi
    sleep 3
done

if [ "$status" != "healthy" ]; then
    printf '\n' >&2
    docker compose logs --tail 40 jarvis >&2 || true
    die "OpenJarvis did not become healthy (status: $status). See the logs above, or run: cd $SCRIPT_DIR && docker compose logs -f jarvis"
fi

# --- Done -------------------------------------------------------------------

case "$bind" in
0.0.0.0 | "::" | "[::]") url_host="localhost" lan_note=1 ;;
*:*) url_host="[$bind]" lan_note="" ;;
*) url_host="$bind" lan_note="" ;;
esac
url="http://${url_host}:${port}"

cat <<EOF

${GREEN}${BOLD}OpenJarvis is running.${RESET}

  Web UI + API   ${BOLD}${url}${RESET}
  Model          ${model}
  API key        ${api_key}

  In the web UI open ${BOLD}Settings -> API key${RESET} and paste the key above.
  API clients send:  Authorization: Bearer <key>   (OpenAI-compatible at ${url}/v1)
EOF
if [ -n "$lan_note" ]; then
    printf '  Published on all interfaces: other devices use http://<this-host-ip>:%s\n' "$port"
fi
cat <<EOF

  Manage it from ${SCRIPT_DIR}:
    docker compose logs -f jarvis                 follow the server logs
    docker compose exec ollama ollama pull <m>    add another local model
    docker compose down                           stop (data is kept)
    git pull && ./install.sh                      update to the latest version
    docker compose down -v                        remove everything, including models and data
EOF
