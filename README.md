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

1. Add {:app_status, git: "https://github.com/semdinsp/app_status.git", tag: "v0.1.2"}
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
       {:app_status, git: "https://github.com/semdinsp/app_status.git", tag: "v0.1.2"}
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

**Nested maps are silently dropped from `/status/metrics`, with no
error.** `AppStatus.PrometheusFormatter` only knows how to turn
numbers/booleans into gauges — anything else (including a nested map)
just isn't emitted as a metric line. It still shows up fine in the JSON
`/status` report, so this is easy to miss. For example:

```elixir
def extra_metrics do
  %{
    # Nested map — visible in JSON /status, but produces zero lines in
    # /status/metrics:
    db_pool: %{pool_size: 10, up?: true},

    # Flat keys — each becomes its own Prometheus gauge:
    db_pool_size: 10,
    db_pool_up: true
  }
end
```

If you want a value queryable in Grafana, flatten it into its own
top-level key rather than nesting it.

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

In both cases the failure detail (exception, stack trace, or exit
reason) is logged locally via `Logger.error/1` — `/status` only ever
shows a generic `"<Module>.extra_metrics/0 failed — see application
logs"` string, never the raw error. This is deliberate: `/status` is
normally unauthenticated (see "Security" below), so a raw stack trace
or GenServer exit reason could otherwise leak internal file paths,
module names, or call arguments to anyone who can reach the endpoint.
Check your own app's logs to debug an `extension_error`.

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

## Security

`/status` and `/status/metrics` are designed to be mounted **without
authentication**, so scrapers (Prometheus, uptime checks) can hit them
without credentials. That's a deliberate tradeoff, not an oversight —
but it means anyone who can reach the host app's HTTP port can:

- See the app's real name/version, BEAM node name (e.g.
  `trading_hub@some-host.local`), hostname, port, uptime, and memory/process
  stats — useful recon for timing an attack around a restart/deploy.
- See whatever a host app's `AppStatus.Extension` exposes (e.g. whether
  a DB or an external connection is currently up) — don't put anything
  in `extra_metrics/0` you wouldn't want an unauthenticated caller to
  see (no raw credentials, connection strings, tokens, or PII; booleans
  and small numeric health indicators are the intended use case).
- As of `v0.1.1`, extension failures are sanitized before they reach
  `/status` (see "Boot-time safety" above) — a raised error or a dead
  `GenServer.call` no longer leaks a stack trace or exit reason into the
  public report, only a generic message pointing at your logs.

If a host app is reachable from the public internet (not just an
internal network/VPN), restrict access to `/status*` at the network
layer — e.g. an IP allowlist or basic auth at the load balancer/reverse
proxy in front of it, scoped to your Prometheus scraper and your own
IPs — rather than relying on anything in this library, which has no
built-in access control by design.

### Production hardening checklist

Pick whichever of these fit your deployment; they're not mutually
exclusive. From least to most work:

1. **Network-level restriction (recommended first line of defense).**
   Don't expose `/status*` to the public internet at all if you can
   avoid it:
   - **Fly.io**: put the scraper (Prometheus/Grafana Agent) on the same
     private network (`.internal` / 6PN) as the app and don't route
     `/status*` through the public `fly-proxy` — e.g. run Prometheus as
     its own Fly app in the same org and scrape over `appname.internal`,
     or restrict the public path at your edge/CDN config.
   - **Behind nginx/Caddy/an ALB**: allowlist `/status*` to your
     scraper's IP(s) and your office/VPN CIDR; deny everyone else with a
     403 before the request ever reaches the BEAM.

2. **Shared-secret header check, enforced in the host app's router**
   (simple, no extra infra). Wrap the `forward` in a plug that checks a
   header before dispatching to `AppStatus.Plug`:

   ```elixir
   # lib/my_app_web/router.ex
   pipeline :status_auth do
     plug :require_status_token
   end

   scope "/status" do
     pipe_through :status_auth
     forward "/", AppStatus.Plug
   end

   defp require_status_token(conn, _opts) do
     expected = Application.fetch_env!(:my_app, :status_token)

     case Plug.Conn.get_req_header(conn, "x-status-token") do
       [^expected] ->
         conn

       _ ->
         conn
         |> Plug.Conn.send_resp(401, "unauthorized")
         |> Plug.Conn.halt()
     end
   end
   ```

   Set `config :my_app, status_token: System.fetch_env!("STATUS_TOKEN")`
   at runtime (`config/runtime.exs`), and configure your Prometheus
   scrape job / uptime checker to send that header. Use
   `Plug.Crypto.secure_compare/2` instead of `==`/pattern-matching if
   you want constant-time comparison against timing attacks.

3. **Basic auth**, if you'd rather not manage a custom header —
   `Plug.BasicAuth` ships with `:plug` itself, already a dependency of
   this library, so no extra deps are needed. It's a function plug, not
   a module plug, and only takes plain string credentials (read them
   from the environment at runtime, don't hardcode them):

   ```elixir
   # lib/my_app_web/router.ex
   scope "/status" do
     plug :status_basic_auth
     forward "/", AppStatus.Plug
   end

   defp status_basic_auth(conn, _opts) do
     Plug.BasicAuth.basic_auth(conn,
       username: System.fetch_env!("STATUS_USERNAME"),
       password: System.fetch_env!("STATUS_PASSWORD")
     )
   end
   ```

General Elixir/Phoenix production security reminders, beyond just this
endpoint: run behind TLS (Fly.io/most PaaS terminate this for you, but
verify `force_ssl` is set in your Endpoint config for anything
internet-facing), never commit secrets to `config/config.exs` — use
`config/runtime.exs` + env vars for anything sensitive, and keep
`mix deps.audit`/`mix hex.audit` in CI to catch known-vulnerable
dependencies.

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

### v0.1.2

- Security: `AppStatus.Extension.call_configured/0` no longer returns
  the raw exception message, stack trace, or `GenServer` exit reason in
  the public `extension_error` field. `/status` is normally mounted
  unauthenticated, so a raw stack trace or exit reason (which can embed
  internal file paths, module/function names, or call arguments) was
  being exposed to anyone who could reach the endpoint. The full detail
  is now logged locally via `Logger.error/1`; `/status` only shows a
  generic `"<Module>.extra_metrics/0 failed — see application logs"`
  message. See "Security" and "Boot-time safety" above.
- Docs: added a "Security" section covering the unauthenticated-by-design
  tradeoff of `/status*` and a production hardening checklist (network
  restriction, shared-secret header, `Plug.BasicAuth`), and documented
  that nested `extra_metrics/0` values are silently dropped from
  `/status/metrics` (numbers/booleans only).

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
