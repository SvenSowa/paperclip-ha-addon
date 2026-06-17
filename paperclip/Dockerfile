# Supervisor injects BUILD_ARCH (aarch64/amd64); select the matching
# Home Assistant Debian base image. BUILD_FROM is no longer provided by the
# Supervisor (>= 2026.04.0), so the base image is pinned here directly.
ARG BUILD_ARCH=amd64
FROM ghcr.io/home-assistant/${BUILD_ARCH}-base-debian:trixie

# ============================================================================
# Metadata
# ============================================================================
LABEL \
    io.hass.name="Paperclip AI" \
    io.hass.description="Multi-Agent Orchestration Platform" \
    io.hass.type="addon" \
    io.hass.version="2.1.4" \
    io.hass.arch="aarch64|amd64" \
    maintainer="GaRoN <garon@example.com>"

# ============================================================================
# Layer 1: System Dependencies (Minimal)
# ============================================================================
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gosu \
        git \
        wget \
        ripgrep \
        python3 \
        openssh-client \
        jq \
        tzdata \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# ============================================================================
# Layer 2: Node.js and pnpm
# ============================================================================
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# Enable corepack and install pnpm with pinned version
RUN corepack enable && \
    corepack prepare pnpm@9.15.2 --activate

# ============================================================================
# Layer 3: User and Directory Setup
# ============================================================================
# The entrypoint starts as root (standard for Home Assistant add-ons) to prepare
# /data, then drops to this unprivileged user via gosu before launching the app.
# Dropping privileges is required: the embedded PostgreSQL refuses to run as root.
# All persistent state lives under /data at runtime (provided & persisted by the
# Supervisor), so no build-time data directories are created here.
RUN useradd -u 1000 -U -M -s /bin/bash paperclip && \
    mkdir -p /app

# ============================================================================
# Layer 4: Paperclip Build
# ============================================================================
ARG PAPERCLIP_VERSION=v2026.609.0
WORKDIR /tmp/paperclip-build

RUN git clone --depth 1 --branch ${PAPERCLIP_VERSION} https://github.com/paperclipai/paperclip.git . && \
    pnpm install --frozen-lockfile && \
    pnpm --filter @paperclipai/ui build && \
    pnpm --filter @paperclipai/plugin-sdk build && \
    pnpm --filter @paperclipai/server build && \
    test -f server/dist/index.js || (echo "ERROR: server build output missing" && exit 1)

# ============================================================================
# Layer 5: Install to Final Location
# ============================================================================
RUN cp -r /tmp/paperclip-build/* /app/ && \
    rm -rf /tmp/paperclip-build

WORKDIR /app

# ============================================================================
# Layer 6: Global CLI Tools
# ============================================================================
RUN npm install --global --omit=dev \
    @anthropic-ai/claude-code@latest \
    @openai/codex@latest \
    opencode-ai

# ============================================================================
# Layer 7: Azure AI Foundry Adapter (external Paperclip adapter)
# ============================================================================
# Build the Azure AI Foundry adapter as a self-contained package under /opt so
# Paperclip can load it as an external adapter (adapterType "azure_foundry").
# It is installed with its own node_modules (including @paperclipai/adapter-utils)
# so the server's dynamic import resolves dependencies without relying on the
# Paperclip workspace layout. run.sh registers it in the adapter-plugins store
# at startup via a localPath record.
#
# AZURE_FOUNDRY_ADAPTER_VERSION pins the version we EXPECT the cloned tag to
# contain. The build fails loudly if the on-disk package.json does not match.
# This guards against a stale Docker cache or a moved git tag silently shipping
# an older adapter (Paperclip reads the version live from this package.json, so
# a stale clone would surface as the wrong version in the UI). Bumping this ARG
# together with AZURE_FOUNDRY_ADAPTER_REF also changes the RUN cache key, forcing
# a fresh clone on the next build.
ARG AZURE_FOUNDRY_ADAPTER_REF=v0.3.3
ARG AZURE_FOUNDRY_ADAPTER_VERSION=0.3.3
RUN git clone --depth 1 --branch ${AZURE_FOUNDRY_ADAPTER_REF} https://github.com/SvenSowa/azure-foundry-adapter.git /opt/azure-foundry-adapter && \
    cd /opt/azure-foundry-adapter && \
    ACTUAL_VERSION="$(jq -r '.version' package.json)" && \
    if [ "${ACTUAL_VERSION}" != "${AZURE_FOUNDRY_ADAPTER_VERSION}" ]; then \
        echo "ERROR: azure-foundry-adapter version mismatch: cloned ${AZURE_FOUNDRY_ADAPTER_REF} contains ${ACTUAL_VERSION}, expected ${AZURE_FOUNDRY_ADAPTER_VERSION}" && exit 1; \
    fi && \
    npm install && \
    npm run build && \
    test -f dist/index.js || (echo "ERROR: azure-foundry-adapter build output missing" && exit 1) && \
    npm prune --omit=dev && \
    rm -rf .git

# ============================================================================
# Layer 8: Entrypoint Script
# ============================================================================
COPY run.sh /usr/local/bin/run.sh
RUN chmod +x /usr/local/bin/run.sh

# ============================================================================
# Environment Variables
# ============================================================================
# All PAPERCLIP_HOME-derived paths point into /data so that the config,
# secrets and the (embedded) database survive add-on restarts and updates.
ENV NODE_ENV=production \
    HOME=/data/paperclip \
    HOST=0.0.0.0 \
    PORT=3100 \
    SERVE_UI=true \
    PAPERCLIP_HOME=/data/paperclip \
    PAPERCLIP_INSTANCE_ID=default \
    PAPERCLIP_CONFIG=/data/paperclip/instances/default/config.json \
    PAPERCLIP_DEPLOYMENT_MODE=authenticated \
    PAPERCLIP_DEPLOYMENT_EXPOSURE=private \
    OPENCODE_ALLOW_ALL_MODELS=true

# ============================================================================
# Expose Port
# ============================================================================
EXPOSE 3100

# ============================================================================
# Entrypoint
# ============================================================================
CMD ["/usr/local/bin/run.sh"]