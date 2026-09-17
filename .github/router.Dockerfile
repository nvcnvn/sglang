# syntax=docker/dockerfile:1.7
# ---------------------------------------------------------------------------
# sglang-router, with this fork's smg_cache_aware_* metrics, as a small image.
# ---------------------------------------------------------------------------
# Published by .github/workflows/router-image.yml to
# ghcr.io/<owner>/sglang-router. Build context is sgl-model-gateway/, not the
# repo root -- the crate is self-contained (6 MB) and nothing else in the
# repo is needed to build the router.
#
#   docker build -f .github/router.Dockerfile -t sglang-router ./sgl-model-gateway
#
# Why NOT FROM lmsysorg/sglang: the router is a standalone process on its own
# port, and its runtime dependencies are setproctitle/aiohttp/orjson/uvicorn/
# fastapi -- no torch, no CUDA. Basing it on the 20 GB engine image to deliver
# a 5 MB wheel would make every pull a 20 GB pull.
#
# Both stages are bookworm, so the glibc the extension module is linked against
# is the glibc it runs on. The pyo3 binding is built with abi3-py38, so the
# resulting cp38-abi3 wheel is valid on any Python >= 3.8 -- the runtime stage's
# Python version can move without a rebuild being wrong.

ARG PYTHON_VERSION=3.11

# ---------------------------------------------------------------------------
# 1. wheel
# ---------------------------------------------------------------------------
FROM rust:1.90-bookworm AS wheel

# Two packages that look redundant and are not:
#
#   libprotobuf-dev  ships the well-known types (google/protobuf/timestamp.proto,
#                    struct.proto) under /usr/include. protobuf-compiler is only
#                    the protoc binary, and smg-grpc-client's proto imports those
#                    files -- without this the build dies in that crate's build
#                    script with "google/protobuf/timestamp.proto: File not found".
#
#   patchelf         maturin links libssl/libcrypto dynamically and rewrites the
#                    RPATH to bundle them into the wheel. Without it the build
#                    fails at the very last step, after the whole dependency tree
#                    has compiled.
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
        protobuf-compiler libprotobuf-dev libssl-dev pkg-config cmake patchelf \
        python3-pip python3-venv \
    && rm -rf /var/lib/apt/lists/*

# sgl-model-gateway/rust-toolchain.toml pins channel 1.90 with the clippy
# component, which this image does not ship -- so cargo would re-sync the whole
# toolchain on every build, inside the build step, uncached. Doing it here makes
# it a layer instead.
RUN rustup toolchain install 1.90 --profile minimal --component clippy

RUN python3 -m venv /venv && /venv/bin/pip install --no-cache-dir --upgrade pip maturin

WORKDIR /src
COPY . /src

WORKDIR /src/bindings/python
# The cache mounts make a rebuild after a one-line edit a minute rather than
# fifteen. The rm is load-bearing with a warm cache: maturin runs patchelf on
# the built .so to bundle libssl/libcrypto and writes the rewritten library
# names back into the artifact cargo keeps, so a second build re-repairs an
# already-repaired .so and fails with "libssl-<hash>.so.3 could not be located".
# Deleting the cdylib alone costs a link step, not a rebuild -- every dependency
# stays cached.
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/target,sharing=locked \
    set -eux; \
    export CARGO_TARGET_DIR=/target; \
    rm -rf /target/maturin /target/release/libsglang_router_rs.so \
           /target/release/deps/libsglang_router_rs*; \
    /venv/bin/maturin build --release --out /wheels; \
    ls -l /wheels

# A failed maturin run can leave a stub .whl behind, and a stub installs without
# complaint and then fails at import time in the router container -- which looks
# like a router bug on the GPU box rather than a build failure here.
RUN python3 -c "\
import glob, zipfile, sys; \
w = glob.glob('/wheels/*.whl'); \
assert len(w) == 1, w; \
assert any(n.endswith('.so') for n in zipfile.ZipFile(w[0]).namelist()), 'no compiled extension in wheel'; \
print('wheel ok:', w[0])"

# ---------------------------------------------------------------------------
# 2. runtime
# ---------------------------------------------------------------------------
FROM python:${PYTHON_VERSION}-slim-bookworm AS runtime

# curl is here for the container healthcheck, which compose defines as
# `curl -sf http://127.0.0.1:8000/health`. python:slim does not ship it.
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
        curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Pinned to the wheel's declared runtime dependencies, installed as their own
# layer so a new wheel does not re-resolve them.
RUN pip install --no-cache-dir \
        setproctitle aiohttp orjson uvicorn fastapi

COPY --from=wheel /wheels/*.whl /tmp/
# --no-deps: the line above is the dependency set, and it is deliberate.
RUN pip install --no-cache-dir --no-deps /tmp/*.whl \
    && rm -f /tmp/*.whl \
    && python3 -c "import sglang_router, sglang_router.sglang_router_rs as rs; \
print('sglang_router', sglang_router.__file__)"

# 8000 the request path, 29000 /metrics. The router defaults --prometheus-port
# to None, i.e. NO metrics at all, so the port is only live if the caller passes
# --prometheus-port=29000; compose.router.yaml in the lab does.
EXPOSE 8000 29000

ENTRYPOINT ["python3", "-m", "sglang_router.launch_router"]
