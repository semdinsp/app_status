# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`app_status` is a small, dependency-light Elixir library (not a standalone app)
that gives every Phoenix/Elixir app in this workspace a consistent `/status`
(JSON) and `/status/metrics` (Prometheus text) endpoint. It's meant to be
added as a git dependency to host apps like `trading_hub` and `trading_system`
so they all report uptime, BEAM memory/process stats, and app-specific health
metrics the same way, without copy-pasting the same module into each app.

Because it declares a `mod:` entry in `mix.exs`, OTP auto-starts
`AppStatus.Application` (and its `AppStatus.Collector` GenServer) as soon as
a host app loads this dependency — no wiring needed in the host app's own
`application.ex`.

## Commands

```bash
# Fetch deps
mix deps.get

# Compile (treat warnings as errors before considering a change done)
mix compile --warnings-as-errors

# Run tests
mix test

# Run a single test file
mix test test/app_status/report_test.exs

# Format
mix format
```

There's no standalone server here — this repo only compiles and tests the
library in isolation. To see it running for real, it must be mounted inside
a host Phoenix app via `forward "/status", AppStatus.Plug`.

## Architecture

- `AppStatus.Application` — OTP application callback; starts the one child,
  `AppStatus.Collector`.
- `AppStatus.Collector` — GenServer that builds a status report snapshot on
  init and refreshes it every 5s (`@refresh_interval_ms`), so concurrent or
  frequent scrapes don't recompute `:erlang.memory/0` etc. per-request. Falls
  back to building a fresh report inline if the GenServer isn't up.
- `AppStatus.Report` — pure functions that gather the actual snapshot: app
  name/version/git SHA, node/host/port, uptime, BEAM memory, process/port/atom
  counts vs. limits, scheduler counts, Fly.io region/machine env vars (if
  present), and whatever the host app's `AppStatus.Extension` supplies.
- `AppStatus.Extension` — behaviour a host app implements to inject
  app-specific metrics (DB pool stats, IBKR connection state, etc.) via
  `config :app_status, extension: MyApp.StatusExtension`. Swallows and reports
  extension errors as `extension_error` rather than crashing the report.
- `AppStatus.Plug` — a `Plug.Router` exposing `GET /` (JSON) and
  `GET /metrics` (Prometheus text); mounted by host apps via
  `forward "/status", AppStatus.Plug`.
- `AppStatus.PrometheusFormatter` — converts the report map into Prometheus
  text exposition format. Only numeric/boolean values from `extra` get
  exported as gauges (booleans coerce to 1/0); strings are JSON-only.

## Host app configuration contract

Host apps add this as a git dependency (repo: `https://github.com/semdinsp/app_status.git`):

```elixir
# mix.exs
{:app_status, git: "https://github.com/semdinsp/app_status.git", tag: "v0.1.4"}
```

Then configure it via their own `config/config.exs`:

```elixir
config :app_status,
  app_name: :my_app,
  endpoint: MyAppWeb.Endpoint,
  access_log_interval: 60,           # seconds (default: 60, use 0 for all, false for none)
  extension: MyApp.StatusExtension  # optional
```

`git_sha` is typically set at build time via `config/runtime.exs` or a
Dockerfile/fly.toml build arg (`GIT_SHA` env var also works and takes
precedence).

When changing `AppStatus.Report`'s output shape, remember every host app
(`trading_hub`, `trading_system`, etc.) depends on this same report map for
both its JSON and Prometheus output — keep changes additive/backward
compatible unless you're prepared to update all host apps and their Grafana
dashboards together.
