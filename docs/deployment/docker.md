# Docker Deployment

OpenJarvis ships a ready-to-run Docker Compose stack: the OpenJarvis API server
with its web UI, an [Ollama](https://ollama.com) inference backend, and a
one-shot job that downloads the model on first start. CPU, NVIDIA and AMD ROCm
image variants are available.

## Quick Start (one command)

Requirements: Docker Engine with the Compose v2 plugin (**2.24 or newer**), and
about 10 GB of free disk space for the image and a small model.

```bash
git clone https://github.com/open-jarvis/OpenJarvis.git
cd OpenJarvis
deploy/docker/install.sh
```

The installer:

1. checks that Docker and Compose are usable;
2. creates `deploy/docker/.env` from `.env.example` and generates a random
   `OPENJARVIS_API_KEY` (an existing `.env` and key are kept);
3. builds the image (the first build compiles the Rust extension and takes
   several minutes);
4. starts Ollama and pulls the model (`qwen3.5:2b` by default), showing the
   download progress;
5. starts OpenJarvis and waits until its health check passes;
6. prints the URL and the API key.

Open the printed URL (default <http://127.0.0.1:1337>), go to
**Settings → API key** and paste the key. That's it.

### Installer options

| Option | Effect |
|---|---|
| `--model NAME` | Ollama model to serve and pre-pull, e.g. `qwen3.5:9b` |
| `--gpu cpu\|nvidia\|rocm` | Image variant. `nvidia` requires the [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html) |
| `--port N` | Host port for the web UI + API (default `1337`) |
| `--bind ADDR` / `--lan` | Host interface to publish on. Default `127.0.0.1` (this machine only); `--lan` publishes on `0.0.0.0` |

Every choice is written to `deploy/docker/.env` (the GPU variant as
`COMPOSE_FILE`), so plain `docker compose ...` commands run from
`deploy/docker/` keep using the same settings. Re-running the installer is
safe and is also the update path:

```bash
git pull && deploy/docker/install.sh
```

## Manual Setup

If you prefer to drive Compose yourself:

```bash
cd deploy/docker
cp .env.example .env
# Set OPENJARVIS_API_KEY in .env, for example:
sed -i "s/^OPENJARVIS_API_KEY=.*/OPENJARVIS_API_KEY=$(openssl rand -hex 32)/" .env
docker compose up -d --build
```

Compose refuses to start if `OPENJARVIS_API_KEY` is empty: the container binds
`0.0.0.0`, and the server will not listen on a non-loopback address without a
key. The first `up` waits for the model download before starting the server;
follow it with `docker compose logs -f ollama-pull`.

For a GPU host add the matching override file:

```bash
docker compose -f docker-compose.yml -f docker-compose.gpu.nvidia.yml up -d --build
```

## What Runs

| Service | Port (host) | Description |
|---|---|---|
| `jarvis` | `127.0.0.1:1337` | OpenJarvis API server (OpenAI-compatible `/v1`) and web UI |
| `ollama` | `127.0.0.1:11434` | Ollama inference engine. Loopback only: Ollama has no authentication |
| `ollama-pull` | – | One-shot job that pulls missing models, then exits |

`jarvis` starts only after Ollama is healthy and `ollama-pull` has finished,
because `jarvis serve` exits when no model is available. Models already in the
volume are not downloaded again, so restarts also work offline. All services
restart automatically (`unless-stopped`) and their logs are rotated (3 × 10 MB).

## Configuration

All settings live in `deploy/docker/.env` (see `.env.example` for the
commented template). The whole file is also passed to the OpenJarvis
container, so any other variable OpenJarvis reads (for example tool or channel
tokens) can be added there too.

| Variable | Default | Description |
|---|---|---|
| `OPENJARVIS_API_KEY` | – (required) | Bearer key for `/v1/*` and `/api/*` |
| `OPENJARVIS_MODEL` | `qwen3.5:2b` | Default model served by OpenJarvis |
| `OLLAMA_PULL` | `$OPENJARVIS_MODEL` | Space-separated models to pre-pull; empty skips pulling |
| `OPENJARVIS_BIND` | `127.0.0.1` | Host interface for the web UI + API |
| `OPENJARVIS_PORT` | `1337` | Host port for the web UI + API |
| `OLLAMA_PORT` | `11434` | Host port for Ollama (always loopback) |
| `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`, `OPENROUTER_API_KEY` | – | Enable cloud models next to the local ones |
| `OPENJARVIS_EXTRAS` | `server inference-cloud inference-google` | Optional-dependency groups baked into the image (build time; must include `server`) |
| `OPENJARVIS_IMAGE` | `openjarvis:local` | Image tag to build/run (`openjarvis:local-cuda` / `-rocm` for the GPU variants) |
| `COMPOSE_FILE` | `docker-compose.yml` | Set by `install.sh --gpu` to include a GPU override |

After changing `.env`, apply it with `docker compose up -d` (add `--build`
when you changed `OPENJARVIS_EXTRAS`).

### Reaching OpenJarvis from other devices

Set `OPENJARVIS_BIND=0.0.0.0` (or run `install.sh --lan`). The API key is sent
with every request, so on anything other than a trusted network put a TLS
reverse proxy (Caddy, Traefik, nginx) in front of port 1337 instead of exposing
it directly.

### Using a cloud model

Add a provider key to `.env` and point the server at one of its models, for
example:

```bash
OPENAI_API_KEY=sk-...
OPENJARVIS_MODEL=gpt-4o-mini
OLLAMA_PULL=            # nothing to download for a cloud-only setup
```

Local Ollama models stay available alongside the cloud ones.

## Using the API

```bash
KEY=$(grep '^OPENJARVIS_API_KEY=' deploy/docker/.env | cut -d= -f2-)

curl http://127.0.0.1:1337/health            # no key needed

curl http://127.0.0.1:1337/v1/models -H "Authorization: Bearer $KEY"

curl http://127.0.0.1:1337/v1/chat/completions \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"model": "qwen3.5:2b", "messages": [{"role": "user", "content": "Hello!"}]}'
```

Any OpenAI-compatible client works with base URL `http://127.0.0.1:1337/v1`
and the key as its API key.

## Data and Persistence

Two named volumes hold all state:

| Volume | Mounted at | Contents |
|---|---|---|
| `openjarvis_openjarvis-data` | `/home/openjarvis/.openjarvis` | `config.toml`, memory / traces / telemetry databases, saved credentials, skills |
| `openjarvis_ollama-models` | `/root/.ollama` (in `ollama`) | Downloaded models |

`docker compose down` keeps both; `docker compose down -v` deletes them.

Back up the OpenJarvis data volume:

```bash
docker run --rm -v openjarvis_openjarvis-data:/data -v "$PWD":/backup \
  python:3.12-slim tar czf /backup/openjarvis-data.tgz -C /data .
```

!!! note "Upgrading from an older Compose file"
    Earlier versions of `docker-compose.yml` had no project name, so Compose
    derived it from the directory (`docker`) and named the model volume
    `docker_ollama-models`. The stack is now named `openjarvis`. To keep using
    already-downloaded models, either run once with `COMPOSE_PROJECT_NAME=docker`
    or copy the old volume into `openjarvis_ollama-models`.

### Custom `config.toml`

The server reads `~/.openjarvis/config.toml`, which is
`/home/openjarvis/.openjarvis/config.toml` inside the container (it runs as
the unprivileged `openjarvis` user, UID 10001). Write a config into the data
volume as that user (so OpenJarvis can still update it) and restart:

```bash
docker compose exec -T jarvis sh -c 'umask 077; cat > ~/.openjarvis/config.toml' < my-config.toml
docker compose restart jarvis
```

The `--model` passed by the Compose file (`OPENJARVIS_MODEL`) takes precedence
over the model in `config.toml`.

## GPU Acceleration

### NVIDIA

```bash
deploy/docker/install.sh --gpu nvidia
```

This uses `Dockerfile.gpu` (CUDA 12.4 runtime) for the server and reserves all
GPUs for both the server and Ollama, so local inference runs on the GPU. The
host needs the [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html).

### AMD ROCm

```bash
deploy/docker/install.sh --gpu rocm
```

This uses `Dockerfile.gpu.rocm` and passes `/dev/kfd` and `/dev/dri` to the
server container. The bundled Ollama service keeps the CPU image; for GPU
inference through Ollama on AMD, switch its image to Ollama's `-rocm` variant
and give it the same devices.

## Standalone Image

Build the image from the repository root:

```bash
docker build -f deploy/docker/Dockerfile -t openjarvis:local .
```

The build is multi-stage and reproducible: the frontend is built in a pinned
`node` stage, Python dependencies are installed from the committed `uv.lock`
(`uv export --frozen`, no re-resolution), the native Rust extension is compiled
with the toolchain from `rust/rust-toolchain.toml`, and the runtime stage is a
slim Python image running as the unprivileged `openjarvis` user. All base
images are pinned by digest.

Select optional dependencies with a build argument:

```bash
docker build -f deploy/docker/Dockerfile -t openjarvis:local \
  --build-arg OPENJARVIS_EXTRAS="server inference-cloud memory-faiss" .
```

Run it standalone (state persisted in a named volume):

```bash
export OPENJARVIS_API_KEY="$(openssl rand -hex 32)"
docker run -d --name openjarvis \
  -e OPENJARVIS_API_KEY \
  -v openjarvis-data:/home/openjarvis/.openjarvis \
  -p 127.0.0.1:1337:8000 \
  openjarvis:local
```

### Running the image against a host Ollama server

Ollama must already be running on the host with a model installed and
listening on an address reachable from containers. On Linux, its default
loopback-only binding is not reachable via the Docker host gateway; configure
its binding using the
[Ollama server instructions](https://docs.ollama.com/faq#how-do-i-configure-ollama-server)
and restrict access to trusted container traffic.

```bash
docker run -d --name openjarvis \
  -e OPENJARVIS_API_KEY \
  -e OLLAMA_HOST=http://host.docker.internal:11434 \
  -v openjarvis-data:/home/openjarvis/.openjarvis \
  -p 127.0.0.1:8001:8000 \
  --add-host host.docker.internal:host-gateway \
  openjarvis:local serve --engine ollama --host 0.0.0.0 --port 8000
```

Map each additional container to a different host port to run several
instances side by side.

### Overriding the command

The entrypoint is `jarvis` and the default command is
`serve --host 0.0.0.0 --port 8000`, so any CLI subcommand can be run:

```bash
docker run --rm -e OPENJARVIS_API_KEY openjarvis:local --help
docker compose exec jarvis jarvis --version
```

Available options for `jarvis serve`:

| Option | Description |
|---|---|
| `--host` | Bind address (default: from config, typically `127.0.0.1`) |
| `--port` | Port number (default: from config, typically `8000`) |
| `-e` / `--engine` | Engine backend (`ollama`, `vllm`, `llamacpp`, `sglang`, `cloud`, ...) |
| `-m` / `--model` | Default model name |
| `-a` / `--agent` | Agent for chat requests (`simple`, `orchestrator`, `react`, `openhands`) |

## Health Check

`GET /health` needs no API key and reports whether the inference engine is
reachable: HTTP 200 `{"status": "ok"}` when healthy, HTTP 503 otherwise. The
Compose file uses it as the container health check (with Python, since the
slim image has no `curl`), so `docker compose ps` shows `healthy` once the
server is ready.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `required variable OPENJARVIS_API_KEY is missing a value` | Run `install.sh`, or set the key in `deploy/docker/.env` |
| `jarvis` never starts, `ollama-pull` exited with an error | Check `docker compose logs ollama-pull`: usually no internet access or a misspelled model name. Fix `OPENJARVIS_MODEL` and run `docker compose up -d` |
| `jarvis` is `unhealthy` | `docker compose logs jarvis`; `/health` returns 503 while Ollama is unreachable |
| `port is already allocated` | Choose another port: `install.sh --port 8080` |
| `permission denied ... docker.sock` | Add your user to the `docker` group (log out and back in) or use `sudo` |
| `env_file ... required` / unknown key errors | Docker Compose is older than 2.24; update it |
| Web UI shows 401 errors | Paste the key from `.env` under **Settings → API key** |
