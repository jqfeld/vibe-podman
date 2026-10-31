# Mistral Vibe sandbox: uv (Python), Zig, Typst + on-demand Julia (juliaup) and Rust (rustup)
#
# Build:  podman build -t vibe:latest .
# Run:    ./run-vibe.sh            (GPU passthrough on by default)
#         ./run-vibe.sh --help     (all options)
#
# Toolchain managers (juliaup, rustup, uv) are installed, but NO Julia or Rust
# toolchain is baked into the image. They are downloaded on demand at first use
# inside the container; run-vibe.sh persists them in named volumes:
#   Julia:  juliaup default release    (or: juliaup add 1.13 && juliaup default 1.13)
#   Rust:   rustup default stable      (or: rustup toolchain install stable)
#
# The container sees only the mounted working directory (/workspace).
# $HOME/.vibe is mounted from the host so auth/config persist between runs.
# GPU passthrough needs the NVIDIA Container Toolkit on the host; CUDA 13.x
# images need host driver >= 580.

# ARGs used in FROM lines must be declared *before* the first FROM:
# podman/buildah does not pick up ARGs that sit between two stages.
#
# Base image: NVIDIA CUDA on Ubuntu. Override via --build-arg, e.g.
#   --build-arg CUDA_IMAGE=nvidia/cuda:13.4.3-devel-ubuntu26.04   (adds nvcc)
#   --build-arg CUDA_IMAGE=nvidia/cuda:12.8.1-base-ubuntu24.04     (older host driver)
ARG UV_VERSION=latest
ARG CUDA_IMAGE=nvidia/cuda:13.4.3-base-ubuntu26.04

# uv/uvx static binaries (official image; pin UV_VERSION for reproducible builds)
FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv

FROM ${CUDA_IMAGE}

ARG JULIAUP_VERSION=1.23.0
ARG ZIG_VERSION=0.17.0
ARG TYPST_VERSION=0.15.1
ARG PYTHON_VERSION=3.13

ENV DEBIAN_FRONTEND=noninteractive

# --- System packages + CLI tools that make Vibe more effective ---
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl git \
    build-essential pkg-config libssl-dev \
    ripgrep jq procps \
    unzip xz-utils zstd \
    shellcheck cmake \
    && rm -rf /var/lib/apt/lists/*

# --- Typst (static musl binary) ---
RUN ARCH=$(uname -m) \
    && curl -fsSL "https://github.com/typst/typst/releases/download/v${TYPST_VERSION}/typst-${ARCH}-unknown-linux-musl.tar.xz" \
       | tar -xJ -C /tmp \
    && mv "/tmp/typst-${ARCH}-unknown-linux-musl/typst" /usr/local/bin/ \
    && rm -rf /tmp/typst-*

# --- Zig (compiler + stdlib, supports C/C++ cross-compilation out of the box) ---
RUN ARCH=$(uname -m) \
    && curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${ARCH}-linux-${ZIG_VERSION}.tar.xz" \
       | tar -xJ -C /opt \
    && ln -s "/opt/zig-${ARCH}-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig

# --- uv (Python package/project manager) ---
COPY --from=uv /uv /uvx /usr/local/bin/

# --- Non-root user ---
# Ubuntu 24.04+ images ship user "ubuntu" (UID 1000); drop it so vibe gets UID 1000.
RUN userdel -r ubuntu 2>/dev/null || true \
    && useradd -m -u 1000 -s /bin/bash vibe
USER vibe
WORKDIR /home/vibe

ENV PATH="/home/vibe/.local/bin:/home/vibe/.cargo/bin:/home/vibe/.juliaup/bin:${PATH}"

# uv config: only use uv-managed Pythons; copy (don't hardlink) between the uv
# cache and /workspace, which lives on a different filesystem when mounted.
# VIBE_ENABLE_AUTO_UPDATE=false: keep the CLI pinned to what the image ships.
ENV UV_LINK_MODE=copy \
    UV_PYTHON_PREFERENCE=only-managed \
    UV_PYTHON_INSTALL_DIR=/home/vibe/.local/share/uv/python \
    UV_CACHE_DIR=/home/vibe/.cache/uv \
    VIBE_ENABLE_AUTO_UPDATE=false

# --- rustup only — NO Rust toolchain at build time ---
# Installs the rustc/cargo proxy commands, but no toolchain. First use inside
# the container: `rustup default stable` (downloaded on demand, kept in a
# named volume via run-vibe.sh).
RUN curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs \
    | sh -s -- -y --profile default --default-toolchain none --no-modify-path

# --- juliaup only — NO Julia toolchain at build time ---
# The install.julialang.org installer would pull a default Julia channel, so
# take the juliaup binary straight from the GitHub release instead. `julia` is
# the same binary (juliaup multiplexes on argv[0]). First use inside the
# container: `juliaup default release` (downloaded on demand, kept in a named
# volume via run-vibe.sh).
RUN ARCH=$(uname -m) \
    && mkdir -p /home/vibe/.juliaup/bin /tmp/juliaup-extract \
    && curl -fsSL -o /tmp/juliaup.tar.gz \
       "https://github.com/JuliaLang/juliaup/releases/download/v${JULIAUP_VERSION}/juliaup-${JULIAUP_VERSION}-${ARCH}-unknown-linux-musl-portable.tar.gz" \
    && tar -xzf /tmp/juliaup.tar.gz -C /tmp/juliaup-extract \
    && find /tmp/juliaup-extract -type f -name juliaup -exec install -m 0755 {} /home/vibe/.juliaup/bin/juliaup \; \
    && cp /home/vibe/.juliaup/bin/juliaup /home/vibe/.juliaup/bin/julia \
    && rm -rf /tmp/juliaup.tar.gz /tmp/juliaup-extract \
    && juliaup --version

# Julia package depot (used once a Julia toolchain is installed on demand)
RUN mkdir -p /home/vibe/.julia

# --- Python (uv-managed) + Mistral Vibe CLI ---
# Python itself is needed at build time (the CLI runs on it);
# Julia/Rust stay strictly on demand.
RUN uv python install --default ${PYTHON_VERSION} \
    && uv tool install mistral-vibe \
    && uv cache clean

# On-demand toolchain hints in interactive shells
RUN cat >> /home/vibe/.bashrc <<'EOF'
# On-demand toolchains (persisted in named volumes, see run-vibe.sh):
#   juliaup default release    # install the latest Julia
#   rustup default stable      # install the latest Rust
EOF

# --- Workspace: the only host directory visible inside the container ---
WORKDIR /workspace

ENTRYPOINT ["vibe"]
