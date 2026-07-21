defmodule AppStatus.ExtensionTest do
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

  test "call_configured/0 returns an empty map when no extension is configured" do
    Application.delete_env(:app_status, :extension)

    assert AppStatus.Extension.call_configured() == %{}
  end

  test "call_configured/0 returns extension metrics on success" do
    Application.put_env(:app_status, :extension, AppStatus.ExtensionTest.OkExtension)

    assert AppStatus.Extension.call_configured() == %{ok: true}
  end

  test "call_configured/0 rescues a raised error without crashing the caller" do
    Application.put_env(:app_status, :extension, AppStatus.ExtensionTest.RaisingExtension)

    assert %{extension_error: message} = AppStatus.Extension.call_configured()
    assert message =~ "boom"
  end

  test "call_configured/0 catches an :exit from a GenServer.call to an unregistered process" do
    Application.put_env(:app_status, :extension, AppStatus.ExtensionTest.DeadCallExtension)

    assert %{extension_error: message} = AppStatus.Extension.call_configured()
    assert message =~ "no process"
  end

  test "call_configured/0 times out a hung extra_metrics/0 instead of blocking forever" do
    Application.put_env(:app_status, :extension, AppStatus.ExtensionTest.HangingExtension)

    assert %{extension_error: message} = AppStatus.Extension.call_configured()
    assert message =~ "timed out"
  end

  test "the collector survives and reports extension_error instead of crashing" do
    Application.put_env(:app_status, :extension, AppStatus.ExtensionTest.DeadCallExtension)

    pid = Process.whereis(AppStatus.Collector)
    assert pid && Process.alive?(pid)

    send(pid, :refresh)
    # Let the async refresh (which runs the extension via a Task) complete.
    Process.sleep(50)

    report = AppStatus.Collector.get()

    assert Process.alive?(pid)
    assert Process.whereis(AppStatus.Collector) == pid
    assert %{extension_error: message} = report.extra
    assert message =~ "no process"
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
