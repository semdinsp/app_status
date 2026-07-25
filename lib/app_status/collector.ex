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

  @doc """
  Checks if an access log should be emitted for status endpoints based on `access_log_interval`.
  Returns `true` if this access should log, `false` if it should be suppressed.

  Always returns `true` when the runtime `Logger` level is `:debug`, so
  suppression never hides status-endpoint logs from a debug session.
  """
  def should_log_access? do
    if Logger.level() == :debug do
      true
    else
      case access_log_interval() do
        :always -> true
        :never -> false
        seconds when is_integer(seconds) and seconds > 0 -> check_and_update_interval(seconds)
      end
    end
  end

  def reset_access_log_timer! do
    GenServer.call(__MODULE__, :reset_access_log_timer)
  catch
    :exit, _ -> :ok
  end

  defp check_and_update_interval(seconds) do
    GenServer.call(__MODULE__, {:check_access_log, seconds})
  catch
    :exit, _ -> true
  end

  # --- Server ---------------------------------------------------------

  @impl true
  def init(_opts) do
    state = %{
      started_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      report: nil,
      last_access_log_at: nil
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

  def handle_call({:check_access_log, seconds}, _from, state) do
    now = System.monotonic_time(:second)

    case state.last_access_log_at do
      last_logged when is_integer(last_logged) and now - last_logged < seconds ->
        {:reply, false, state}

      _ ->
        {:reply, true, %{state | last_access_log_at: now}}
    end
  end

  def handle_call(:reset_access_log_timer, _from, state) do
    {:reply, :ok, %{state | last_access_log_at: nil}}
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
