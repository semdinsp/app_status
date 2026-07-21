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
            db_pool: MyApp.Repo.checked_out_stats(),
            ibkr_connected: MyApp.IBKR.connected?()
          }
        end
      end

  `extra_metrics/0` must return a flat, JSON-encodable map. Keep keys
  namespaced (e.g. `:ibkr_connected` not `:connected`) since they get
  merged into the top-level report and flattened for Prometheus export.
  """

  @callback extra_metrics() :: map()

  @doc false
  def call_configured do
    case Application.get_env(:app_status, :extension) do
      nil ->
        %{}

      module ->
        try do
          module.extra_metrics()
        rescue
          error ->
            %{extension_error: Exception.format(:error, error)}
        end
    end
  end
end
