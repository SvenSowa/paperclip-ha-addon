# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.1.5] - 2026-06-17

### Changed
- Bumped the bundled Azure AI Foundry adapter to `v0.3.4`.

### Fixed
- Adapter now handles Azure rate limiting (HTTP 429) gracefully: the retry
  back-off is abort-aware (a run timeout or cancel no longer waits out a long
  `Retry-After` before failing), the back-off is capped at 30s, and exhausted
  retries / aborts now produce a clear message ("Azure rate limit (HTTP 429) …
  raise the deployment's Tokens-Per-Minute quota") instead of the bare
  "This operation was aborted".
- The Foundry adapter now updates on the **first** rebuild. A cache-bust step
  fetches the adapter tag's live commit metadata before cloning, so a
  moved/updated tag invalidates the Docker clone layer immediately (previously a
  second rebuild was sometimes needed to pick up adapter changes).

## [2.1.4] - 2026-06-17

### Changed
- Bumped the bundled Azure AI Foundry adapter to `v0.3.3`.

### Fixed
- Runs no longer fail with "Failed to parse URL from
  /openai/v1/chat/completions". The execute paths now fall back to the
  `AZURE_FOUNDRY_ENDPOINT` env var (set from the addon's `azure_foundry.endpoint`
  config) at request time, matching the Test button's behaviour — previously the
  endpoint was only resolved during validation, so runs that relied on the
  addon-level endpoint produced a relative URL.
- The "Foundry run" log now reports the actual resolved deployment
  (`config.model`) instead of always showing `(default)`.

## [2.1.3] - 2026-06-17

### Changed
- Bumped the bundled Azure AI Foundry adapter to `v0.3.2`
  (`AZURE_FOUNDRY_ADAPTER_REF` / `AZURE_FOUNDRY_ADAPTER_VERSION`).

### Fixed
- The deployment selected in Paperclip's native **Model** dropdown is now
  actually used by the adapter's environment test and runs. Paperclip writes
  the model selection to `config.model`; the adapter now reads the Azure
  deployment from `config.model` (with `config.deployment` kept for
  back-compat), resolving the "Deployment not set" warning even after picking
  one.
- Removed the adapter's redundant custom **Deployment** combobox; the standard
  Model dropdown (populated with live Azure deployments) is the single source.

## [2.1.2] - 2026-06-17

### Changed
- Bumped the bundled Azure AI Foundry adapter to `v0.3.1`
  (`AZURE_FOUNDRY_ADAPTER_REF` / `AZURE_FOUNDRY_ADAPTER_VERSION`).

### Removed
- The redundant `azure_foundry.deployment` option. The deployment is now
  selected per-agent from the live dropdown in the Paperclip UI, which is
  populated from the resource's real Azure deployments. `endpoint` and
  `api_key` remain (they feed the adapter's live-deployment discovery hook).

### Fixed
- Deployment picker now lists only the resource's real Azure deployments;
  the static `gpt-5-*` suggestion list is used only as a fallback when no
  Foundry credentials are configured yet.

## [2.1.1] - 2026-06-17

### Fixed
- Build-time assertion that the cloned Azure AI Foundry adapter tag matches the
  expected version, busting stale Docker cache layers that pinned an old adapter
  build.

## [2.1.0] - 2026-06-17

### Added
- Azure AI Foundry external adapter (`adapterType: azure_foundry`), baked into
  the image at `/opt/azure-foundry-adapter` and registered with Paperclip's
  adapter-plugin store at startup via a local-path record.
- New `azure_foundry` configuration group: `enabled` toggle plus optional
  `endpoint`, `api_key`, and `deployment` connection defaults (exported as
  `AZURE_FOUNDRY_ENDPOINT` / `AZURE_FOUNDRY_API_KEY` / `AZURE_FOUNDRY_DEPLOYMENT`).
  Per-agent `adapterConfig` in the Paperclip UI overrides these.

## [1.0.0] - 2026-04-21

### Added
- Initial release of Paperclip AI Home Assistant Add-on
- Multi-Agent Orchestration Platform for AI Agents
- Full Debian Trixie build environment
- Web UI and API endpoint (port 3100)
- Ingress integration for Home Assistant panel access
- SQLite and PostgreSQL database support
- OpenClaw integration for agent management
- Configurable deployment modes (authenticated, public, local)
- Comprehensive backup and retention system

### Features
- Multi-agent orchestration platform
- Support for aarch64 and amd64 architectures
- Application-based startup with auto-boot
- Ingress panel integration with robot icon
- Configurable log levels (trace, debug, info, warning, error)
- Database type selection (SQLite or PostgreSQL)
- OpenClaw URL and API key configuration
- Deployment exposure control (private or public)
- Feature toggles for telemetry, routines, workspaces, and feedback
- Performance tuning (max concurrent runs, timeout, heartbeat interval)
- Automated backup system with configurable retention

### Configuration
- Log level configuration
- Database settings (type, SQLite path, PostgreSQL connection details)
- OpenClaw integration (enabled/disabled, URL, API key)
- Deployment mode (authenticated, public, local)
- Exposure settings (private, public)
- Feature flags (telemetry, routines, workspaces, feedback)
- Performance settings (max concurrent runs, timeout, heartbeat interval)
- Backup configuration (enabled, retention days, backup path)