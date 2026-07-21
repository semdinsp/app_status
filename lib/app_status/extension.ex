defmodule AppStatus.Extension do
  @moduledoc """
  Optional behaviour a host app can implement to inject app-specific
  metrics (DB pool stats, external connection health, etc.) into the
  shared /status report.

  Configure it in the host app:

      config :app_status, extension: MyApp.StatusExtension

  and implement it:

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

  `extra_metrics/0` must return a flat, JSON-encodable map. Keep keys
  namespaced (e.g. `:ibkr_connected` not `:connected`) since they get
  merged into the top-level report and flattened for Prometheus export.

  Keep it flat, not nested: `AppStatus.PrometheusFormatter` only turns
  numbers and booleans into Prometheus gauges. A nested map value (e.g.
  `db_pool: %{pool_size: 10, up?: true}`) still shows up fine in the
  JSON `/status` report, but is silently skipped — no error — when
  rendering `/status/metrics`, since it isn't a number or boolean itself.
  Flatten it instead (`db_pool_size: 10, db_pool_up: true`) if you want
  it queryable in Prometheus/Grafana.

  ### Boot-time ordering

  `app_status` starts as its own OTP application, independently of the
  host app's supervision tree — there's no guarantee the host app's own
  processes are up yet when `extra_metrics/0` is first called (it runs
  on `AppStatus.Collector`'s refresh timer, which starts immediately).
  If `extra_metrics/0` does a `GenServer.call` to a process that isn't
  registered yet, that raises an `:exit` signal, not a normal exception.

  `call_configured/0` guards against this on the library side (see
  below), so a not-yet-ready dependency can't crash the collector.
  Still, as a defensive nicety in your own implementation, consider
  checking `Process.whereis/1` (or equivalent) before calling into your
  own GenServers, so you get a clean `nil`/`:not_ready` value in
  `extra_metrics/0` instead of relying on the library to catch the exit:

      def extra_metrics do
        if Process.whereis(MyApp.IBKR.Connection) do
          %{ibkr_connected: MyApp.IBKR.connected?()}
        else
          %{ibkr_connected: false}
        end
      end

  This is guidance for a cleaner report, not a substitute for the
  library-side fix — `call_configured/0` will never crash regardless.
  """

  @callback extra_metrics() :: map()

  @call_timeout_ms 2_000

  @doc false
  def call_configured do
    case Application.get_env(:app_status, :extension) do
      nil ->
        %{}

      module ->
        safe_call(module)
    end
  end

  # Runs extra_metrics/0 in a separate process so that:
  #   - an :exit signal (e.g. GenServer.call to an unregistered/dead
  #     process, common during host-app boot ordering) can't propagate
  #     to and crash AppStatus.Collector, only rescue-able errors can be
  #     caught in-process.
  #   - a hung call (e.g. GenServer.call to a slow process) can't block
  #     the collector's refresh cycle forever; it's bounded by a timeout.
  defp safe_call(module) do
    task =
      Task.async(fn ->
        try do
          {:ok, module.extra_metrics()}
        rescue
          error -> {:error, Exception.format(:error, error, __STACKTRACE__)}
        catch
          kind, reason -> {:error, Exception.format(kind, reason, __STACKTRACE__)}
        end
      end)

    case Task.yield(task, @call_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, metrics}} when is_map(metrics) ->
        metrics

      {:ok, {:ok, other}} ->
        %{extension_error: "extra_metrics/0 returned non-map: #{inspect(other)}"}

      {:ok, {:error, formatted}} ->
        %{extension_error: formatted}

      nil ->
        %{extension_error: "extra_metrics/0 timed out after #{@call_timeout_ms}ms"}
    end
  end
end
