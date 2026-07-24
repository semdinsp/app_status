defmodule AppStatus.Collector do
  @moduledoc """
  Tracks process start time and keeps a cached snapshot of the status
  report, refreshed on a short interval. This keeps `/status` and
  `/status/metrics` cheap even if they're scraped frequently or hit
  concurrently, since we don't recompute `:erlang.memory/0` etc. on
  every single request.
  """
  use GenServer

  @refresh_interval_ms 5_000

  # --- Client API ---------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "UTC ISO8601 timestamp of when this node started."
  def started_at do
    GenServer.call(__MODULE__, :started_at)
  catch
    :exit, _ -> DateTime.utc_now() |> DateTime.to_iso8601()
  end

  @doc """
  Returns the most recently cached report, building one on first call.
  """
  def get do
    GenServer.call(__MODULE__, :get)
  catch
    # If the collector isn't up for some reason, fall back to a
    # freshly-built report rather than failing the request.
    :exit, _ -> AppStatus.Report.build(DateTime.utc_now() |> DateTime.to_iso8601())
  end

  @ets_table :app_status_access_log

  @doc """
  Checks if an access log should be emitted for status endpoints based on `access_log_interval`.
  Returns `true` if this access should log, `false` if it should be suppressed.
  """
  def should_log_access? do
    case access_log_interval() do
      :always ->
        true

      :never ->
        false

      seconds when is_integer(seconds) and seconds > 0 ->
        now = System.monotonic_time(:second)
        table = ensure_ets_table()

        case :ets.lookup(table, :last_access_log_at) do
          [{:last_access_log_at, last_logged}] when now - last_logged < seconds ->
            false

          _ ->
            :ets.insert(table, {:last_access_log_at, now})
            true
        end
    end
  end

  def reset_access_log_timer! do
    table = ensure_ets_table()
    :ets.delete(table, :last_access_log_at)
    :ok
  end

  defp ensure_ets_table do
    case :ets.whereis(@ets_table) do
      :undefined ->
        try do
          :ets.new(@ets_table, [:set, :public, :named_table, read_concurrency: true])
        rescue
          ArgumentError -> @ets_table
        end

      _tid ->
        @ets_table
    end
  end

  # --- Server ---------------------------------------------------------

  @impl true
  def init(_opts) do
    state = %{
      started_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      report: nil
    }

    # Build the first snapshot immediately, then refresh on a timer.
    send(self(), :refresh)
    :timer.send_interval(@refresh_interval_ms, :refresh)

    {:ok, state}
  end

  @impl true
  def handle_call(:started_at, _from, state) do
    {:reply, state.started_at, state}
  end

  def handle_call(:get, _from, %{report: nil} = state) do
    report = AppStatus.Report.build(state.started_at)
    {:reply, report, %{state | report: report}}
  end

  def handle_call(:get, _from, state) do
    {:reply, state.report, state}
  end

  @impl true
  def handle_info(:refresh, state) do
    {:noreply, %{state | report: AppStatus.Report.build(state.started_at)}}
  end

  # --- Helpers --------------------------------------------------------

  defp access_log_interval do
    case get_first_env([:access_log_interval, :log_interval_seconds, :access_log]) do
      {:ok, val} -> parse_interval(val)
      :error -> 60
    end
  end

  defp get_first_env([]), do: :error

  defp get_first_env([key | rest]) do
    case Application.fetch_env(:app_status, key) do
      {:ok, val} -> {:ok, val}
      :error -> get_first_env(rest)
    end
  end

  defp parse_interval(val) when val in [false, :never, :none, :disabled], do: :never
  defp parse_interval(val) when val in [true, :always, :every_access, 0], do: :always
  defp parse_interval(val) when is_integer(val) and val > 0, do: val
  defp parse_interval(_), do: 60
end
