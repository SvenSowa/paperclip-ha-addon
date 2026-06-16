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
# Public URL (useful when accessed through a reverse proxy / external hostname).
PUBLIC_URL="$(bashio::config 'public_url')"
if ! bashio::var.is_empty "${PUBLIC_URL}"; then
    export PAPERCLIP_PUBLIC_URL="${PUBLIC_URL}"
    bashio::log.info "Public URL: ${PUBLIC_URL}"
fi

# Telemetry opt-out (verified upstream env vars).
if [ "$(bashio::config 'disable_telemetry')" = "true" ]; then
    export DO_NOT_TRACK=1
    export PAPERCLIP_TELEMETRY_DISABLED=1
    bashio::log.info "Telemetry disabled"
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
