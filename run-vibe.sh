#!/usr/bin/env bash
# run-vibe.sh — run the Mistral Vibe CLI in a GPU-enabled sandbox container.
#
# Usage: ./run-vibe.sh [options] [--] [vibe-args...]
#
# Options:
#   --gpu          Pass all NVIDIA GPUs into the container (default)
#   --no-gpu       Start the container without GPU access
#   --shell        Start an interactive bash instead of the Vibe CLI
#   --image TAG    Image to run (default: $VIBE_IMAGE or "vibe:latest")
#   --dir DIR      Host directory mounted as /workspace (default: current dir)
#   --ephemeral    Skip the named volumes that persist on-demand toolchains
#   -h, --help     Show this help
#
# Anything after "--" (or any non-option argument, e.g. a prompt string) is
# passed to `vibe`.
#
# Examples:
#   ./run-vibe.sh                              # vibe with GPU, cwd as workspace
#   ./run-vibe.sh --no-gpu                     # CPU-only run
#   ./run-vibe.sh --shell                      # shell into the container
#   ./run-vibe.sh -- "fix the failing tests"   # start vibe with a prompt
#   ./run-vibe.sh --dir ~/src/proj --shell
#
# On-demand toolchains (persisted in named volumes):
#   juliaup default release    # install the latest Julia
#   rustup default stable      # install the latest Rust
#
# Host prerequisites for GPU passthrough (driver >= 580 for CUDA 13.x):
#   podman:  NVIDIA Container Toolkit + CDI spec:
#              sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
#   docker:  NVIDIA Container Toolkit configured for the docker daemon.

set -euo pipefail

die()  { echo "run-vibe.sh: $*" >&2; exit 1; }
warn() { echo "run-vibe.sh: warning: $*" >&2; }

usage() {
  sed -n '3,/^set -euo/p' "$0" | sed '$d;s/^# \{0,1\}//' >&2
}

IMAGE="${VIBE_IMAGE:-vibe:latest}"
WORKSPACE="$(pwd -P)"
GPU=1
SHELL_MODE=0
EPHEMERAL=0
VIBE_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --gpu)        GPU=1 ;;
    --no-gpu)     GPU=0 ;;
    --shell)      SHELL_MODE=1 ;;
    --ephemeral)  EPHEMERAL=1 ;;
    --image)  [[ $# -ge 2 ]] || die "--image needs an argument"; IMAGE="$2"; shift ;;
    --dir)    [[ $# -ge 2 ]] || die "--dir needs an argument";   WORKSPACE="$2"; shift ;;
    -h|--help)    usage; exit 0 ;;
    --) shift; VIBE_ARGS+=("$@"); break ;;
    -*) die "unknown option: $1 (use -- to pass flags to vibe)" ;;
    *)  VIBE_ARGS+=("$1") ;;   # e.g. an initial prompt
  esac
  shift
done

# --- Container runtime (podman preferred, docker as fallback) ---
RUNTIME="${CONTAINER_RUNTIME:-}"
if [[ -z "$RUNTIME" ]]; then
  if command -v podman >/dev/null 2>&1; then RUNTIME=podman; else RUNTIME=docker; fi
fi
command -v "$RUNTIME" >/dev/null 2>&1 \
  || die "container runtime '$RUNTIME' not found (install podman or docker)"

[[ -d "$WORKSPACE" ]] || die "workspace directory not found: $WORKSPACE"
WORKSPACE="$(cd "$WORKSPACE" && pwd -P)"

# --- Host dir for Vibe auth/config (persisted across runs) ---
VIBE_HOME="${VIBE_HOME:-$HOME/.vibe}"
mkdir -p "$VIBE_HOME"

# --- Named volumes so on-demand toolchains survive --rm containers ---
# On first use, the engine copies the image content (incl. ownership) into the
# volume, so rustup/juliaup proxies and uv-managed Pythons keep working.
VOLS=()
add_toolchain_volumes() {
  local v target
  while read -r v target; do
    # Only create if missing: podman volume create errors if the volume
    # already exists (docker's is idempotent, but this works for both).
    "$RUNTIME" volume inspect "$v" >/dev/null 2>&1 \
      || "$RUNTIME" volume create "$v" >/dev/null
    VOLS+=("-v" "$v:$target")
  done <<'VOLLIST'
vibe-rustup /home/vibe/.rustup
vibe-cargo /home/vibe/.cargo
vibe-juliaup /home/vibe/.juliaup
vibe-julia /home/vibe/.julia
vibe-uv /home/vibe/.local/share/uv
vibe-uv-cache /home/vibe/.cache/uv
VOLLIST
}
[[ "$EPHEMERAL" -eq 1 ]] || add_toolchain_volumes

# --- GPU passthrough (default on) ---
GPU_FLAGS=()
if [[ "$GPU" -eq 1 ]]; then
  if [[ "$RUNTIME" == "podman" ]]; then
    GPU_FLAGS=(--device nvidia.com/gpu=all --security-opt label=disable)
    if ! compgen -G '/etc/cdi/*.y*ml' >/dev/null \
       && ! compgen -G '/var/run/cdi/*.y*ml' >/dev/null; then
      warn "no NVIDIA CDI spec found in /etc/cdi or /var/run/cdi"
      warn "generate one: sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml"
    fi
  else
    GPU_FLAGS=(--gpus all)
  fi
fi

# --- Rootless podman: keep host UID 1000 == container UID 1000 (user 'vibe') ---
USERNS_FLAGS=()
if [[ "$RUNTIME" == "podman" && "$(id -u)" != "0" ]]; then
  USERNS_FLAGS=(--userns keep-id)
fi

# --- Run ---
COMMON=(
  --rm -it
  "${GPU_FLAGS[@]}"
  "${USERNS_FLAGS[@]}"
  "${VOLS[@]}"
  -v "$WORKSPACE:/workspace":z
  -v "$VIBE_HOME:/home/vibe/.vibe":z
  -w /workspace
  -e "TERM=${TERM:-xterm-256color}"
)

if [[ "$SHELL_MODE" -eq 1 ]]; then
  exec "$RUNTIME" run "${COMMON[@]}" --entrypoint /bin/bash "$IMAGE"
else
  exec "$RUNTIME" run "${COMMON[@]}" "$IMAGE" "${VIBE_ARGS[@]}"
fi
