defmodule AppStatus.PlugTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  @opts AppStatus.Plug.init([])

  test "GET / returns a pretty-printed JSON status report" do
    conn = conn(:get, "/") |> AppStatus.Plug.call(@opts)

    assert conn.state == :sent
    assert conn.status == 200
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "application/json"

    body = Jason.decode!(conn.resp_body)
    assert Map.has_key?(body, "uptime_seconds")
    assert Map.has_key?(body, "memory")
  end

  test "GET /metrics returns Prometheus text exposition format" do
    conn = conn(:get, "/metrics") |> AppStatus.Plug.call(@opts)

    assert conn.state == :sent
    assert conn.status == 200
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/plain"
    assert conn.resp_body =~ "app_status_uptime_seconds"
  end

  test "unknown routes return 404" do
    conn = conn(:get, "/nope") |> AppStatus.Plug.call(@opts)

    assert conn.state == :sent
    assert conn.status == 404
  end
end
