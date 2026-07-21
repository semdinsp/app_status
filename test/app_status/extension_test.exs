defmodule AppStatus.ExtensionTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

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

  test "call_configured/0 returns an empty map when no extension is configured" do
    Application.delete_env(:app_status, :extension)

    assert AppStatus.Extension.call_configured() == %{}
  end

  test "call_configured/0 returns extension metrics on success" do
    Application.put_env(:app_status, :extension, AppStatus.ExtensionTest.OkExtension)

    assert AppStatus.Extension.call_configured() == %{ok: true}
  end

  test "call_configured/0 rescues a raised error without crashing the caller, and never leaks the message publicly" do
    Application.put_env(:app_status, :extension, AppStatus.ExtensionTest.RaisingExtension)

    log =
      capture_log(fn ->
        assert %{extension_error: message} = AppStatus.Extension.call_configured()
        assert message =~ "RaisingExtension"
        assert message =~ "see application logs"
        refute message =~ "boom"
      end)

    assert log =~ "boom"
  end

  test "call_configured/0 catches an :exit from a GenServer.call to an unregistered process, and never leaks the exit reason publicly" do
    Application.put_env(:app_status, :extension, AppStatus.ExtensionTest.DeadCallExtension)

    log =
      capture_log(fn ->
        assert %{extension_error: message} = AppStatus.Extension.call_configured()
        assert message =~ "DeadCallExtension"
        assert message =~ "see application logs"
        refute message =~ "definitely_not_a_registered_process"
      end)

    assert log =~ "no process"
  end

  test "call_configured/0 times out a hung extra_metrics/0 instead of blocking forever" do
    Application.put_env(:app_status, :extension, AppStatus.ExtensionTest.HangingExtension)

    log =
      capture_log(fn ->
        assert %{extension_error: message} = AppStatus.Extension.call_configured()
        assert message =~ "HangingExtension"
        assert message =~ "see application logs"
      end)

    assert log =~ "timed out"
  end

  test "the collector survives and reports a sanitized extension_error instead of crashing" do
    Application.put_env(:app_status, :extension, AppStatus.ExtensionTest.DeadCallExtension)

    pid = Process.whereis(AppStatus.Collector)
    assert pid && Process.alive?(pid)

    capture_log(fn ->
      send(pid, :refresh)
      # Let the async refresh (which runs the extension via a Task) complete.
      Process.sleep(50)
    end)

    report = AppStatus.Collector.get()

    assert Process.alive?(pid)
    assert Process.whereis(AppStatus.Collector) == pid
    assert %{extension_error: message} = report.extra
    assert message =~ "DeadCallExtension"
    refute message =~ "definitely_not_a_registered_process"
  end

  defmodule OkExtension do
    @behaviour AppStatus.Extension

    @impl true
    def extra_metrics, do: %{ok: true}
  end

  defmodule RaisingExtension do
    @behaviour AppStatus.Extension

    @impl true
    def extra_metrics, do: raise("boom")
  end

  defmodule DeadCallExtension do
    @behaviour AppStatus.Extension

    @impl true
    def extra_metrics do
      GenServer.call(:definitely_not_a_registered_process, :ping)
    end
  end

  defmodule HangingExtension do
    @behaviour AppStatus.Extension

    @impl true
    def extra_metrics do
      Process.sleep(:infinity)
    end
  end
end
