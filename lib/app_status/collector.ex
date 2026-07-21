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

  @doc "Returns the most recently cached report, building one on first call."
  def get do
    GenServer.call(__MODULE__, :get)
  catch
    # If the collector isn't up for some reason, fall back to a
    # freshly-built report rather than failing the request.
    :exit, _ -> AppStatus.Report.build(DateTime.utc_now() |> DateTime.to_iso8601())
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
end
