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

### Prompt for Claude Code

Paste this into Claude Code (or any coding agent) while it's working inside
the host app's repo (e.g. `trading_hub`, `trading_system`):

```
Add the app_status shared library to this app so it gets a standard
/status and /status/metrics endpoint:

1. Add {:app_status, git: "https://github.com/semdinsp/app_status.git", tag: "v0.1.1"}
   to deps() in mix.exs, then run mix deps.get.
2. In config/config.exs, add:
     config :app_status,
       app_name: :THIS_APP_OTP_NAME,
       endpoint: THIS_APP_WEB.Endpoint
   (infer the correct OTP app name and Endpoint module from mix.exs / the
   existing config rather than guessing generic names.)
3. In the router (lib/*_web/router.ex), add:
     forward "/status", AppStatus.Plug
   Mount it outside any :browser/:api pipeline that would force HTML or
   add unwanted plugs (CSRF, auth, etc.) — it should be reachable
   unauthenticated so a scraper/uptime check can hit it.
4. If this app has app-specific health info worth exposing (DB pool
   stats, an external connection like IBKR, etc.), create a
   THIS_APP.StatusExtension module implementing the AppStatus.Extension
   behaviour and set `config :app_status, extension: THIS_APP.StatusExtension`.
   Skip this step if there's nothing obvious to add.
5. Run mix compile --warnings-as-errors and mix test to confirm nothing broke.
6. Start the server and curl /status and /status/metrics locally to confirm
   both return real data (not just that they compile).
```

Manual steps, if you'd rather do it by hand:

1. Add the dependency (git tag pinning recommended so each app upgrades independently):

   ```elixir
   # mix.exs
   def deps do
     [
       {:app_status, git: "https://github.com/semdinsp/app_status.git", tag: "v0.1.1"}
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

This gives you `GET /status` (pretty JSON) and `GET /status/metrics`
(Prometheus text — point a scraper at it whenever you set up Grafana, no
code changes needed). The Collector GenServer auto-starts via OTP's
dependency mechanism and refreshes the snapshot every 5s so scraping
doesn't hammer `:erlang.memory/0` on every hit. App-specific stuff (DB
pool, IBKR connection state) plugs in via the `AppStatus.Extension`
behaviour without touching this repo — see below.

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

### Boot-time safety

`app_status` starts as its own OTP application, independently of the
host app's own supervision tree, so there's no guarantee your app's
processes are up yet the first time `extra_metrics/0` runs — it's called
on `AppStatus.Collector`'s refresh timer, which starts immediately.

As of `v0.1.1`, `AppStatus.Extension.call_configured/0` runs
`extra_metrics/0` in an isolated, time-boxed task, so a bad extension
can never crash the collector:

- If `extra_metrics/0` raises, or does a `GenServer.call` to a process
  that isn't registered yet (a real scenario during boot — this exits
  rather than raising, which a plain `try/rescue` does not catch), the
  report gets an `extension_error` key instead of crashing.
- If `extra_metrics/0` hangs (e.g. a call to a slow/stuck process), it's
  aborted after 2s and reported as a timeout, instead of blocking the
  collector's refresh cycle forever.

Still, for a cleaner report during boot, consider defensively checking
`Process.whereis/1` before calling into your own GenServers:

```elixir
def extra_metrics do
  if Process.whereis(MyApp.IBKR.Connection) do
    %{ibkr_connected: MyApp.IBKR.connected?()}
  else
    %{ibkr_connected: false}
  end
end
```

This is a nicety for a cleaner report, not a substitute for the
library-side fix above — `call_configured/0` will never crash the host
app regardless of what your extension does.

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

## Changelog

### v0.1.1

- Fix: `AppStatus.Extension.call_configured/0` could crash
  `AppStatus.Collector` (and take down the `app_status` application)
  if a host app's `extra_metrics/0` did a `GenServer.call` to a process
  that wasn't registered yet — a real scenario during app boot, since
  `app_status` starts independently of the host app's own supervision
  order. `GenServer.call` in that situation raises an `:exit` signal,
  which the previous `try/rescue`-only guard did not catch. Now runs
  `extra_metrics/0` in an isolated task that catches both rescue-style
  errors and `:exit`, and enforces a 2s timeout so a hung call can't
  block the collector's refresh cycle either. See "Boot-time safety"
  above.

### v0.1.0

- Initial release: `/status` (JSON) and `/status/metrics` (Prometheus)
  endpoints, `AppStatus.Extension` behaviour for host-app-specific
  metrics, Fly.io env var passthrough.
# app_status
