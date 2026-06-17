#!/usr/bin/with-contenv bashio
# shellcheck shell=bash
set -e

# ============================================================================
# Paperclip AI - Home Assistant Add-on entrypoint
#
# Starts as root (to prepare /data and generate secrets), then drops to the
# unprivileged "paperclip" user via gosu to run the Node.js server. Dropping
# privileges is required because the embedded PostgreSQL refuses to run as root.
#
# All persistent state (config, secrets, embedded database, uploads) lives
# under PAPERCLIP_HOME, which is pointed at /data so it survives add-on
# restarts and updates and is included in add-on backups.
# ============================================================================

# Enable shell tracing in debug mode
if [ "$(bashio::config 'log_level')" = "debug" ]; then
    set -x
    bashio::log.info "Debug mode enabled"
fi

bashio::log.info "=========================================="
bashio::log.info "Starting Paperclip AI Add-on"
bashio::log.info "=========================================="

# ----------------------------------------------------------------------------
# Phase 1: Persistent directories
# ----------------------------------------------------------------------------
# PAPERCLIP_HOME is defined in the Dockerfile as /data/paperclip.
PAPERCLIP_HOME="${PAPERCLIP_HOME:-/data/paperclip}"

bashio::log.info "Phase 1: Preparing persistent storage at ${PAPERCLIP_HOME}"
mkdir -p "${PAPERCLIP_HOME}/instances/default"

# ----------------------------------------------------------------------------
# Phase 2: Authentication secret (stable across restarts)
# ----------------------------------------------------------------------------
# BETTER_AUTH_SECRET must stay constant: regenerating it invalidates every
# existing login session. Generate once and persist it under PAPERCLIP_HOME.
SECRET_FILE="${PAPERCLIP_HOME}/.better_auth_secret"
if [ ! -s "${SECRET_FILE}" ]; then
    bashio::log.info "Phase 2: Generating BETTER_AUTH_SECRET (first run)"
    node -e "process.stdout.write(require('crypto').randomBytes(32).toString('hex'))" > "${SECRET_FILE}"
    chmod 600 "${SECRET_FILE}"
else
    bashio::log.info "Phase 2: Reusing existing BETTER_AUTH_SECRET"
fi
BETTER_AUTH_SECRET="$(cat "${SECRET_FILE}")"
export BETTER_AUTH_SECRET

# ----------------------------------------------------------------------------
# Phase 3: Database configuration
# ----------------------------------------------------------------------------
# - embedded  : the server manages its own PostgreSQL under PAPERCLIP_HOME.
#               Leave DATABASE_URL unset so the app uses the embedded engine.
# - postgres  : connect to an external PostgreSQL via DATABASE_URL.
DATABASE_TYPE="$(bashio::config 'database.type')"
bashio::log.info "Phase 3: Database mode: ${DATABASE_TYPE}"

if [ "${DATABASE_TYPE}" = "postgres" ]; then
    POSTGRES_HOST="$(bashio::config 'database.postgres_host')"
    POSTGRES_PORT="$(bashio::config 'database.postgres_port')"
    POSTGRES_USER="$(bashio::config 'database.postgres_user')"
    POSTGRES_PASSWORD="$(bashio::config 'database.postgres_password')"
    POSTGRES_DATABASE="$(bashio::config 'database.postgres_database')"

    # Apply sensible defaults for optional fields.
    POSTGRES_PORT="${POSTGRES_PORT:-5432}"
    POSTGRES_DATABASE="${POSTGRES_DATABASE:-paperclip}"

    if bashio::var.is_empty "${POSTGRES_HOST}" \
        || bashio::var.is_empty "${POSTGRES_USER}" \
        || bashio::var.is_empty "${POSTGRES_PASSWORD}"; then
        bashio::log.fatal "External PostgreSQL selected but host, user, or password is missing."
        bashio::log.fatal "Set database.postgres_host / postgres_user / postgres_password, or switch database.type to 'embedded'."
        exit 1
    fi

    export DATABASE_URL="postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DATABASE}"
    bashio::log.info "Using external PostgreSQL: ${POSTGRES_USER}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DATABASE}"
else
    unset DATABASE_URL
    bashio::log.info "Using embedded PostgreSQL stored under ${PAPERCLIP_HOME}"
fi

# ----------------------------------------------------------------------------
# Phase 4: Optional settings
# ----------------------------------------------------------------------------
# Deployment exposure (private | public). The deployment MODE is fixed to
# "authenticated" (set in the Dockerfile): the only viable mode for an HA
# add-on. "local_trusted" is intentionally not offered because it forces
# loopback-only binding (server.bind=loopback), which makes the add-on
# unreachable through HA ingress and the LAN (both connect via the container
# IP, not loopback).
DEPLOYMENT_EXPOSURE="$(bashio::config 'deployment.exposure')"
if ! bashio::var.is_empty "${DEPLOYMENT_EXPOSURE}"; then
    export PAPERCLIP_DEPLOYMENT_EXPOSURE="${DEPLOYMENT_EXPOSURE}"
fi
bashio::log.info "Deployment: ${PAPERCLIP_DEPLOYMENT_MODE} / ${PAPERCLIP_DEPLOYMENT_EXPOSURE}"

# Automatic database backups (verified upstream PAPERCLIP_DB_BACKUP_* env vars).
if [ "$(bashio::config 'backup.enabled')" = "true" ]; then
    export PAPERCLIP_DB_BACKUP_ENABLED="true"
    export PAPERCLIP_DB_BACKUP_RETENTION_DAYS="$(bashio::config 'backup.retention_days')"
    export PAPERCLIP_DB_BACKUP_INTERVAL_MINUTES="$(bashio::config 'backup.interval_minutes')"

    # Custom backup directory (optional). Default lives under PAPERCLIP_HOME
    # (/data), which already persists, so leave unset to use the app default.
    BACKUP_PATH="$(bashio::config 'backup.path')"
    if ! bashio::var.is_empty "${BACKUP_PATH}"; then
        export PAPERCLIP_DB_BACKUP_DIR="${BACKUP_PATH}"
        mkdir -p "${BACKUP_PATH}"
    fi
    bashio::log.info "DB backups enabled: retention=$(bashio::config 'backup.retention_days')d, interval=$(bashio::config 'backup.interval_minutes')m"
else
    export PAPERCLIP_DB_BACKUP_ENABLED="false"
    bashio::log.info "DB backups disabled"
fi

# Public URL (useful when accessed through a reverse proxy / external hostname).
PUBLIC_URL="$(bashio::config 'public_url')"
if ! bashio::var.is_empty "${PUBLIC_URL}"; then
    export PAPERCLIP_PUBLIC_URL="${PUBLIC_URL}"
    bashio::log.info "Public URL: ${PUBLIC_URL}"
fi

# Allowed hostnames for authenticated/private mode. In this mode Paperclip
# rejects any request whose Host header is not loopback or explicitly allowed.
# Because the add-on binds 0.0.0.0 and is typically reached via the Home
# Assistant host's LAN IP/hostname (or the ingress proxy), those hosts must be
# allowlisted here, otherwise access fails with a "hostname not allowed" error.
ALLOWED_HOSTNAMES=""
for host in $(bashio::config 'allowed_hostnames'); do
    if [ -z "${ALLOWED_HOSTNAMES}" ]; then
        ALLOWED_HOSTNAMES="${host}"
    else
        ALLOWED_HOSTNAMES="${ALLOWED_HOSTNAMES},${host}"
    fi
done
if ! bashio::var.is_empty "${ALLOWED_HOSTNAMES}"; then
    export PAPERCLIP_ALLOWED_HOSTNAMES="${ALLOWED_HOSTNAMES}"
    bashio::log.info "Allowed hostnames: ${ALLOWED_HOSTNAMES}"
else
    bashio::log.warning "No allowed_hostnames configured. Access via a LAN IP/hostname will be rejected in authenticated/private mode (loopback only)."
fi

# Telemetry opt-out (verified upstream env vars).
if [ "$(bashio::config 'disable_telemetry')" = "true" ]; then
    export DO_NOT_TRACK=1
    export PAPERCLIP_TELEMETRY_DISABLED=1
    bashio::log.info "Telemetry disabled"
fi

# ----------------------------------------------------------------------------
# Phase 4b: Azure AI Foundry adapter
# ----------------------------------------------------------------------------
# The Azure AI Foundry adapter is baked into the image at /opt/azure-foundry-adapter
# (built self-contained in the Dockerfile). Paperclip discovers external adapters
# from the adapter-plugins store under PAPERCLIP_HOME. When enabled we upsert a
# localPath record pointing at the built adapter so the server loads it at startup
# (adapterType "azure_foundry"); when disabled we remove the record so it is hidden.
AZURE_FOUNDRY_ADAPTER_DIR="/opt/azure-foundry-adapter"
ADAPTER_STORE_FILE="${PAPERCLIP_HOME}/adapter-plugins.json"
AZURE_FOUNDRY_ADAPTER_TYPE="azure_foundry"

# Ensure the store file exists and contains a valid JSON array.
if [ ! -s "${ADAPTER_STORE_FILE}" ] || ! jq -e 'type == "array"' "${ADAPTER_STORE_FILE}" >/dev/null 2>&1; then
    echo '[]' > "${ADAPTER_STORE_FILE}"
fi

if [ "$(bashio::config 'azure_foundry.enabled')" = "true" ]; then
    if [ -f "${AZURE_FOUNDRY_ADAPTER_DIR}/dist/index.js" ]; then
        ADAPTER_PKG="$(jq -r '.name' "${AZURE_FOUNDRY_ADAPTER_DIR}/package.json")"
        ADAPTER_VER="$(jq -r '.version' "${AZURE_FOUNDRY_ADAPTER_DIR}/package.json")"
        NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        STORE_TMP="$(mktemp)"
        if jq \
            --arg type "${AZURE_FOUNDRY_ADAPTER_TYPE}" \
            --arg pkg "${ADAPTER_PKG}" \
            --arg ver "${ADAPTER_VER}" \
            --arg path "${AZURE_FOUNDRY_ADAPTER_DIR}" \
            --arg now "${NOW}" \
            'map(select(.type != $type)) + [{packageName: $pkg, localPath: $path, version: $ver, type: $type, installedAt: $now}]' \
            "${ADAPTER_STORE_FILE}" > "${STORE_TMP}"; then
            mv "${STORE_TMP}" "${ADAPTER_STORE_FILE}"
            bashio::log.info "Azure AI Foundry adapter registered (${ADAPTER_PKG}@${ADAPTER_VER})"
        else
            rm -f "${STORE_TMP}"
            bashio::log.warning "Failed to register Azure AI Foundry adapter in ${ADAPTER_STORE_FILE}"
        fi

        # Optional connection defaults read from env by the adapter. These are
        # server-level credentials the live-deployment discovery hook needs (it
        # has no per-agent config to read). The deployment itself is chosen
        # per-agent from the live dropdown in the Paperclip UI, so it is not an
        # env default here.
        AZ_ENDPOINT="$(bashio::config 'azure_foundry.endpoint')"
        AZ_API_KEY="$(bashio::config 'azure_foundry.api_key')"
        if ! bashio::var.is_empty "${AZ_ENDPOINT}"; then
            export AZURE_FOUNDRY_ENDPOINT="${AZ_ENDPOINT}"
            bashio::log.info "Azure AI Foundry endpoint: ${AZ_ENDPOINT}"
        fi
        if ! bashio::var.is_empty "${AZ_API_KEY}"; then
            export AZURE_FOUNDRY_API_KEY="${AZ_API_KEY}"
        fi
    else
        bashio::log.warning "Azure AI Foundry adapter enabled but build is missing at ${AZURE_FOUNDRY_ADAPTER_DIR}"
    fi
else
    # Disabled: drop any previously registered record so it disappears from the UI.
    STORE_TMP="$(mktemp)"
    if jq --arg type "${AZURE_FOUNDRY_ADAPTER_TYPE}" \
        'map(select(.type != $type))' \
        "${ADAPTER_STORE_FILE}" > "${STORE_TMP}"; then
        mv "${STORE_TMP}" "${ADAPTER_STORE_FILE}"
    else
        rm -f "${STORE_TMP}"
    fi
    bashio::log.info "Azure AI Foundry adapter disabled"
fi

# ----------------------------------------------------------------------------
# Phase 5: Permissions
# ----------------------------------------------------------------------------
# Ensure the unprivileged user owns its data directory before we drop to it.
chown -R paperclip:paperclip "${PAPERCLIP_HOME}"

# ----------------------------------------------------------------------------
# Phase 6: Start the server
# ----------------------------------------------------------------------------
bashio::log.info "=========================================="
bashio::log.info "Web UI / API : http://0.0.0.0:${PORT:-3100}"
bashio::log.info "Data dir     : ${PAPERCLIP_HOME}"
bashio::log.info "Deployment   : ${PAPERCLIP_DEPLOYMENT_MODE:-authenticated} / ${PAPERCLIP_DEPLOYMENT_EXPOSURE:-private}"
bashio::log.info "Starting Paperclip server..."
bashio::log.info "=========================================="

cd /app

# exec + gosu: drop privileges and hand off PID 1 so the server receives
# SIGTERM/SIGINT directly for a clean shutdown.
exec gosu paperclip node --import ./server/node_modules/tsx/dist/loader.mjs server/dist/index.js
