defmodule AppStatus.Plug.Filter do
  @moduledoc """
  Plug to suppress Phoenix Endpoint and Router logging for status requests when throttled.

  Mount this plug in your host app's `endpoint.ex` before `Plug.Telemetry` / `Phoenix.Logger`:

      # lib/my_app_web/endpoint.ex
      plug AppStatus.Plug.Filter
      plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  When status access logging is throttled, this sets process log level to `:warning`
  before Phoenix emits `[info] GET /status` or `[debug] Processing with AppStatus.Plug`.
  """
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{request_path: path} = conn, _opts) do
    if status_path?(path) and not AppStatus.Collector.should_log_access?() do
      Logger.put_process_level(self(), :warning)
      Plug.Conn.put_private(conn, :plug_logger_log, false)
    else
      conn
    end
  end

  defp status_path?("/status"), do: true
  defp status_path?("/status/metrics"), do: true
  defp status_path?(path) when is_binary(path), do: String.starts_with?(path, "/status/")
  defp status_path?(_), do: false
end
