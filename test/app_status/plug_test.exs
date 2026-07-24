defmodule AppStatus.PlugTest do
  use ExUnit.Case, async: false
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

  describe "access log rate-limiting" do
    setup do
      original_config = Application.get_env(:app_status, :access_log_interval)
      AppStatus.Collector.reset_access_log_timer!()

      on_exit(fn ->
        AppStatus.Collector.reset_access_log_timer!()

        if original_config == nil do
          Application.delete_env(:app_status, :access_log_interval)
        else
          Application.put_env(:app_status, :access_log_interval, original_config)
        end
      end)

      :ok
    end

    test "throttles logging after first call when interval is configured" do
      Application.put_env(:app_status, :access_log_interval, 60)

      # First call in window should log
      assert AppStatus.Collector.should_log_access?() == true

      # Subsequent rapid call within window should return false
      assert AppStatus.Collector.should_log_access?() == false

      # Plug call should set process level to :warning and plug_logger_log to false
      conn = conn(:get, "/") |> AppStatus.Plug.call(@opts)
      assert conn.status == 200
      assert conn.private[:plug_logger_log] == false
      assert Logger.get_process_level(self()) == :warning
    end

    test "always logs when access_log_interval is :always or 0" do
      Application.put_env(:app_status, :access_log_interval, :always)
      assert AppStatus.Collector.should_log_access?() == true
      assert AppStatus.Collector.should_log_access?() == true

      Application.put_env(:app_status, :access_log_interval, 0)
      assert AppStatus.Collector.should_log_access?() == true
    end

    test "never logs when access_log_interval is :never or false" do
      Application.put_env(:app_status, :access_log_interval, false)
      assert AppStatus.Collector.should_log_access?() == false

      conn = conn(:get, "/") |> AppStatus.Plug.call(@opts)
      assert conn.private[:plug_logger_log] == false
      assert Logger.get_process_level(self()) == :warning
    end

    test "AppStatus.Plug.Filter suppresses Endpoint/Router logging on /status paths when throttled" do
      Application.put_env(:app_status, :access_log_interval, false)
      filter_opts = AppStatus.Plug.Filter.init([])

      conn = conn(:get, "/status") |> AppStatus.Plug.Filter.call(filter_opts)
      assert conn.private[:plug_logger_log] == false
      assert Logger.get_process_level(self()) == :warning

      # Non-status path should pass through untouched
      Logger.put_process_level(self(), :info)
      conn_other = conn(:get, "/api/users") |> AppStatus.Plug.Filter.call(filter_opts)
      assert conn_other.private[:plug_logger_log] == nil
      assert Logger.get_process_level(self()) == :info
    end
  end
end
