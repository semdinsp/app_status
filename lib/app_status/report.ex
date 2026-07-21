defmodule AppStatus.Report do
  @moduledoc """
  Gathers a snapshot of BEAM/VM, app, and (optionally) host-app-specific
  metrics into a single flat-ish map. This is the single source of truth
  consumed by both the JSON endpoint and the Prometheus formatter.
  """

  @doc """
  Builds the full status report. `started_at` is passed in (rather than
  fetched via a GenServer call back to AppStatus.Collector) because this
  function is normally invoked from inside the Collector process itself
  on its refresh timer — calling back into itself would deadlock.
  """
  @spec build(String.t()) :: map()
  def build(started_at) do
    %{
      app: app_name(),
      version: app_version(),
      git_sha: System.get_env("GIT_SHA") || Application.get_env(:app_status, :git_sha),
      node: node(),
      host: hostname(),
      port: http_port(),
      started_at: started_at,
      uptime_seconds: uptime_seconds(),
      memory: memory(),
      process: process_stats(),
      scheduler: scheduler_stats(),
      fly: fly_info(),
      extra: AppStatus.Extension.call_configured()
    }
  end

  defp app_name do
    case Application.get_env(:app_status, :app_name) do
      nil ->
        case Application.started_applications() |> List.first() do
          {name, _, _} -> to_string(name)
          _ -> "unknown"
        end

      name ->
        to_string(name)
    end
  end

  defp app_version do
    otp_app = Application.get_env(:app_status, :app_name)

    case otp_app && Application.spec(otp_app, :vsn) do
      nil -> "unknown"
      vsn -> to_string(vsn)
    end
  end

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> to_string(name)
      _ -> "unknown"
    end
  end

  defp http_port do
    otp_app = Application.get_env(:app_status, :app_name)
    endpoint = Application.get_env(:app_status, :endpoint)

    with true <- is_atom(otp_app) and not is_nil(otp_app),
         true <- is_atom(endpoint) and not is_nil(endpoint),
         config when is_list(config) <- Application.get_env(otp_app, endpoint),
         http when is_list(http) <- config[:http] do
      http[:port]
    else
      _ -> System.get_env("PORT")
    end
  end

  defp uptime_seconds do
    {wall_clock_ms, _since_last_call} = :erlang.statistics(:wall_clock)
    div(wall_clock_ms, 1000)
  end

  defp memory do
    :erlang.memory() |> Map.new()
  end

  defp process_stats do
    %{
      count: :erlang.system_info(:process_count),
      limit: :erlang.system_info(:process_limit),
      run_queue: :erlang.statistics(:run_queue),
      atom_count: :erlang.system_info(:atom_count),
      atom_limit: :erlang.system_info(:atom_limit),
      port_count: :erlang.system_info(:port_count),
      port_limit: :erlang.system_info(:port_limit)
    }
  end

  defp scheduler_stats do
    %{
      schedulers: :erlang.system_info(:schedulers),
      schedulers_online: :erlang.system_info(:schedulers_online)
    }
  end

  defp fly_info do
    %{
      region: System.get_env("FLY_REGION"),
      alloc_id: System.get_env("FLY_ALLOC_ID"),
      machine_id: System.get_env("FLY_MACHINE_ID"),
      app_name: System.get_env("FLY_APP_NAME")
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
