# syntax=docker/dockerfile:1

# Builder and runtime share a base so the venv's ABI and absolute paths match.
ARG PYTHON_IMAGE=python:3.13-slim-trixie

FROM ${PYTHON_IMAGE} AS builder
COPY --from=ghcr.io/astral-sh/uv:0.9 /uv /bin/uv
WORKDIR /app
ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never

# Dependencies first: this layer only rebuilds when the lockfile moves.
COPY pyproject.toml uv.lock ./
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --locked --no-dev --no-install-project

COPY README.md ./
COPY src ./src
# --no-editable: install the package into site-packages rather than leaving a
# .pth pointing at /app/src, so the runtime stage needs only /app/.venv.
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --locked --no-dev --no-editable


FROM ${PYTHON_IMAGE} AS runtime

# Pick up Debian security fixes published since the base image was built
# (apt, zlib1g, ...). Only already-installed packages move; nothing is added.
RUN apt-get update \
    && apt-get upgrade -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*

# ffprobe/ffmpeg drive the whole pipeline (probe, extract, render, verify).
# Static builds rather than Debian's ffmpeg package: that package hard-depends
# on libllvm + mesa-libgallium + flite (~220 MB of GPU and text-to-speech stack)
# that a CPU-only audio muter never invokes. Pinning one build also keeps the
# ffmpeg version identical across amd64 and arm64, so the version branch in
# mute.filter_script_args() resolves the same way on both.
COPY --from=mwader/static-ffmpeg:7.1.1 /ffmpeg /ffprobe /usr/local/bin/

# yt-dlp needs a JS runtime to solve YouTube's "n challenge". The bin- image is
# an official multi-arch image containing only the deno binary.
COPY --from=denoland/deno:bin-2.9.6 /deno /usr/local/bin/deno

COPY --from=builder /app/.venv /app/.venv
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh

ENV PATH=/app/.venv/bin:$PATH \
    BK_CONFIG_DIR=/config \
    HF_HOME=/cache \
    HOME=/config \
    PYTHONUNBUFFERED=1 \
    BK_MEDIA_ROOT=/media \
    BK_WEB_PORT=8080 \
    BK_WEB_HOST=0.0.0.0

# 0.0.0.0 above is the *container's* interface, not an exposure decision: a
# container's loopback is its own, so a server bound to 127.0.0.1 inside would
# be unreachable through any published port. Restrict access on the host side
# by publishing to 127.0.0.1:8080:8080 (which is what compose does).
EXPOSE 8080

# /config holds config.toml and marker.key — the per-machine key that makes
# already-cleaned files skippable. Keep it on a persistent volume or every run
# re-transcribes everything. /cache holds the whisper model (~460 MB).
RUN mkdir -p /config /cache /media && chown 1000:1000 /config /cache
VOLUME ["/config", "/cache"]

# Meaningful for `serve`; a one-shot CLI container exits long before it matters.
# Probes loopback inside the container, so it works whatever BK_WEB_HOST is.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD ["python", "-c", "import os,urllib.request as u; u.urlopen('http://127.0.0.1:%s/api/config' % os.environ.get('BK_WEB_PORT','8080'), timeout=4)"]

WORKDIR /media
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

ARG VERSION=dev
LABEL org.opencontainers.image.title="blasphemy-killer" \
      org.opencontainers.image.description="Scan video and audio files for phrases that take the Lord's name in vain and mute them" \
      org.opencontainers.image.source="https://github.com/dhomoney/Blasphemy-Killer" \
      org.opencontainers.image.version="${VERSION}"
