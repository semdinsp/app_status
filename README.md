# AppStatus

A small, dependency-light Elixir app that gives every one of your
Phoenix/Elixir apps a consistent `/status` (JSON) and `/status/metrics`
(Prometheus text) endpoint — without copy-pasting the same module into
each app.

Reports:

- App name, version, git SHA, node name, hostname, HTTP port
- Uptime
- BEAM memory breakdown (`total`, `processes`, `binary`, `ets`, `atom`, ...)
- Process/port/atom counts vs. limits, run queue length
- Scheduler counts
- Fly.io region/machine/alloc info (if present as env vars)
- Anything app-specific you supply via `AppStatus.Extension`

## Install in a host app

1. Add the dependency (git tag pinning recommended so each app upgrades independently):

   ```elixir
   # mix.exs
   def deps do
     [
       {:app_status, git: "https://github.com/you/app_status.git", tag: "v0.1.0"}
       # ...
     ]
   end
   ```

2. Configure it — this tells AppStatus which OTP app / Endpoint to introspect
   for version and port info:

   ```elixir
   # config/config.exs
   config :app_status,
     app_name: :my_app,
     endpoint: MyAppWeb.Endpoint
   ```

3. Mount it in your router:

   ```elixir
   # lib/my_app_web/router.ex
   forward "/status", AppStatus.Plug
   ```

4. (Optional) Set the git SHA at build time so `/status` tells you exactly
   what's deployed:

   ```elixir
   # config/runtime.exs or your Dockerfile/fly.toml build args
   config :app_status, git_sha: System.get_env("GIT_SHA")
   ```

That's it — `mix deps.get && mix compile` and OTP will auto-start
`AppStatus.Application` (and its Collector) as part of your app's
supervision tree, no changes to your own `application.ex` needed.

## Adding app-specific metrics

Implement the `AppStatus.Extension` behaviour for things this shared
lib can't know about — DB pool stats, an external API's connection
state, etc:

```elixir
defmodule MyApp.StatusExtension do
  @behaviour AppStatus.Extension

  @impl true
  def extra_metrics do
    %{
      db_pool_checked_out: MyApp.Repo.checked_out_count(),
      ibkr_connected: MyApp.IBKR.connected?()
    }
  end
end
```

```elixir
# config/config.exs
config :app_status, extension: MyApp.StatusExtension
```

Numeric and boolean values in `extra_metrics/0` are automatically
exported to `/status/metrics` too (booleans become 1/0, Prometheus
convention for up/down values). String values show up in the JSON
report but are skipped in the Prometheus export.

## Wiring up Grafana

`/status/metrics` is already valid Prometheus exposition format, so:

1. Point a Prometheus scrape job at each app's `https://<app>.fly.dev/status/metrics`
2. Import/build one Grafana dashboard with an `app` label filter/dropdown —
   since every app exports the same metric names, one dashboard covers
   trading-risk, skisites4, and shelley-plants at once.
3. If you outgrow this later (want histograms for request duration
   percentiles, per-route breakdowns, LiveView metrics, etc.), swap
   this formatter out for [PromEx](https://hexdocs.pm/prom_ex) — it
   reads from the same `:telemetry` events Phoenix/Ecto already emit
   and ships pre-built dashboards. Nothing here blocks that migration;
   you'd just add PromEx as a dependency and mount its plug alongside
   (or instead of) this one.

## Endpoints

- `GET /status` — JSON, pretty-printed
- `GET /status/metrics` — Prometheus text exposition format

## Local dev

```
mix deps.get
mix compile
```

There's no standalone server in this repo — it's meant to be mounted
inside a host Phoenix app via `forward "/status", AppStatus.Plug`.
# app_status
