defmodule AppStatus.Plug do
  @moduledoc """
  Mountable Plug.Router exposing the status report.

  In a Phoenix app, forward to it from your router:

      forward "/status", AppStatus.Plug

  This gives you:

    * `GET /status`         - JSON report (human-readable, for curl/browser)
    * `GET /status/metrics` - Prometheus text exposition format (for scraping)

  Works in any Plug-based app (Phoenix or bare Plug/Cowboy), since it
  only depends on `:plug` and `:jason`, not Phoenix itself.
  """
  use Plug.Router

  plug :match
  plug :dispatch

  get "/" do
    report = AppStatus.Collector.get()

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(report, pretty: true))
  end

  get "/metrics" do
    report = AppStatus.Collector.get()
    body = AppStatus.PrometheusFormatter.format(report)

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, body)
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
