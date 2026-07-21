defmodule AppStatus.ReportTest do
  use ExUnit.Case, async: false

  setup do
    original = Application.get_all_env(:app_status)

    on_exit(fn ->
      for {key, _} <- Application.get_all_env(:app_status) do
        Application.delete_env(:app_status, key)
      end

      for {key, value} <- original do
        Application.put_env(:app_status, key, value)
      end
    end)

    :ok
  end

  test "build/1 includes the given started_at timestamp" do
    report = AppStatus.Report.build("2024-01-01T00:00:00Z")

    assert report.started_at == "2024-01-01T00:00:00Z"
  end

  test "build/1 reports app name from config" do
    Application.put_env(:app_status, :app_name, :my_app)

    report = AppStatus.Report.build("now")

    assert report.app == "my_app"
  end

  test "build/1 falls back to a started application name when app_name is unset" do
    Application.delete_env(:app_status, :app_name)

    report = AppStatus.Report.build("now")

    assert is_binary(report.app)
  end

  test "build/1 includes BEAM memory, process, and scheduler stats" do
    report = AppStatus.Report.build("now")

    assert is_map(report.memory)
    assert Map.has_key?(report.memory, :total)

    assert %{count: _, limit: _, run_queue: _} = report.process
    assert %{schedulers: _, schedulers_online: _} = report.scheduler
  end

  test "build/1 reports uptime as a non-negative integer" do
    report = AppStatus.Report.build("now")

    assert is_integer(report.uptime_seconds)
    assert report.uptime_seconds >= 0
  end

  test "build/1 omits fly info keys when the env vars aren't set" do
    report = AppStatus.Report.build("now")

    assert report.fly == %{}
  end

  test "build/1 includes fly info when env vars are present" do
    System.put_env("FLY_REGION", "sea")

    report = AppStatus.Report.build("now")

    assert report.fly[:region] == "sea"
  after
    System.delete_env("FLY_REGION")
  end

  test "build/1 defaults extra to an empty map when no extension is configured" do
    Application.delete_env(:app_status, :extension)

    report = AppStatus.Report.build("now")

    assert report.extra == %{}
  end

  test "build/1 merges extension-provided metrics into extra" do
    Application.put_env(:app_status, :extension, AppStatus.ReportTest.FakeExtension)

    report = AppStatus.Report.build("now")

    assert report.extra == %{db_pool_checked_out: 3, ibkr_connected: true}
  end

  defmodule FakeExtension do
    @behaviour AppStatus.Extension

    @impl true
    def extra_metrics do
      %{db_pool_checked_out: 3, ibkr_connected: true}
    end
  end
end
