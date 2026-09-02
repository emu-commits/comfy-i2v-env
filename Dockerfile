# syntax=docker/dockerfile:1.7

# A ComfyUI image-to-video runtime, built once and pulled onto rented GPUs.
#
# The point of baking an image rather than installing at boot is NOT to save
# bandwidth -- the bytes cross the wire either way. It is to move CPU work off
# the meter: wheel unpacking, dependency resolution, and above all any nvcc
# compilation, which is minutes of GPU rent spent not rendering.
#
# Model weights are deliberately NOT baked in. They are fetched at boot, pinned
# by revision, so that a host can pull only the precision variant its GPU can
# actually use instead of carrying every variant on every pull.

ARG BASE_DEVEL
ARG BASE_RUNTIME

# --------------------------------------------------------------------------
# Stage 1: build. The devel base carries nvcc, which the runtime base does not.
# --------------------------------------------------------------------------
FROM ${BASE_DEVEL} AS builder

ARG TORCH_CHANNEL
ARG TORCH_VERSION

# Compiled CUDA extensions are architecture-specific. This image has to run on
# whatever the spot market offers, so every architecture we are willing to rent
# must be in the fat binary -- otherwise the extension either JITs from PTX on
# first use (slow, and it looks like a bad benchmark rather than a bug) or fails
# outright. 8.0 A100 / 8.6 Ampere / 8.9 Ada / 9.0 Hopper / 12.0 Blackwell.
ENV TORCH_CUDA_ARCH_LIST="8.0 8.6 8.9 9.0 12.0+PTX" \
    DEBIAN_FRONTEND=noninteractive \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1

RUN apt-get update && apt-get install -y --no-install-recommends \
        python3.12 python3.12-venv python3.12-dev build-essential git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN python3.12 -m venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

RUN pip install --upgrade pip wheel setuptools \
    && pip install "torch==${TORCH_VERSION}" torchvision torchaudio \
        --index-url "https://download.pytorch.org/whl/${TORCH_CHANNEL}"

# Extension point. Anything that must be compiled against torch belongs here, so
# that the compile happens once, in CI, on someone else's electricity. Empty by
# default: an image whose only content is unpacked wheels is barely worth more
# than a hash-pinned lockfile, and adding a build here is what earns it its keep.
ARG EXTENSIONS=""
RUN if [ -n "${EXTENSIONS}" ]; then pip install --no-build-isolation ${EXTENSIONS}; fi

# --------------------------------------------------------------------------
# Stage 2: runtime. No nvcc, no build-essential, no apt lists, no caches.
# --------------------------------------------------------------------------
FROM ${BASE_RUNTIME} AS runtime

ARG COMFYUI_REPO
ARG COMFYUI_SHA

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PATH="/opt/venv/bin:${PATH}" \
    PYTHONDONTWRITEBYTECODE=1 \
    HF_HOME=/workspace/hf \
    COMFYUI_PATH=/opt/ComfyUI

RUN apt-get update && apt-get install -y --no-install-recommends \
        python3.12 libgl1 libglib2.0-0 git ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /opt/venv /opt/venv

# Fetch exactly one commit, then delete the git metadata: .git carries remotes,
# author addresses and reflogs, none of which belong in a public image.
RUN git init /opt/ComfyUI \
    && cd /opt/ComfyUI \
    && git remote add origin "${COMFYUI_REPO}" \
    && git fetch --depth 1 origin "${COMFYUI_SHA}" \
    && git checkout FETCH_HEAD \
    && rm -rf /opt/ComfyUI/.git \
    && pip install -r /opt/ComfyUI/requirements.txt

# Weights land here at boot, on the instance's own disk, never in a layer.
RUN mkdir -p /workspace/hf /opt/ComfyUI/models

# Final scrub. Everything below is a thing that has leaked out of somebody's
# container image before: credential helpers, caches keyed to a build user,
# shell history, and pip's record of where it was invoked from.
RUN rm -rf /root/.cache /root/.npm /root/.gitconfig /root/.git-credentials \
           /root/.netrc /root/.ssh /root/.docker /root/.bash_history \
           /tmp/* /var/tmp/* /var/log/* \
    && find / -xdev -name "*.pyc" -delete 2>/dev/null || true

WORKDIR /opt/ComfyUI
EXPOSE 8188
CMD ["python", "main.py", "--listen", "0.0.0.0", "--port", "8188"]

LABEL org.opencontainers.image.title="comfy-i2v-env" \
      org.opencontainers.image.description="ComfyUI image-to-video runtime with precompiled CUDA extensions. Weights fetched at boot." \
      org.opencontainers.image.source="https://github.com/emu-commits/comfy-i2v-env" \
      org.opencontainers.image.licenses="GPL-3.0-only"
