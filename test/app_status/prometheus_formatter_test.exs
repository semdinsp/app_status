defmodule AppStatus.PrometheusFormatterTest do
  use ExUnit.Case, async: true

  @report %{
    app: "my_app",
    node: :my_app@localhost,
    uptime_seconds: 42,
    memory: %{total: 1_000_000, processes: 500_000},
    process: %{count: 10, limit: 100_000},
    scheduler: %{schedulers: 8, schedulers_online: 8},
    extra: %{db_pool_checked_out: 3, ibkr_connected: true, sync_ok: false, region: "sea"}
  }

  test "includes app and node labels" do
    output = AppStatus.PrometheusFormatter.format(@report)

    assert output =~ ~s(app="my_app")
    assert output =~ ~s(node="my_app@localhost")
  end

  test "renders uptime, memory, process, and scheduler gauges" do
    output = AppStatus.PrometheusFormatter.format(@report)

    assert output =~ "app_status_uptime_seconds{app=\"my_app\",node=\"my_app@localhost\"} 42"
    assert output =~ "app_status_memory_total_bytes"
    assert output =~ "app_status_process_count"
    assert output =~ "app_status_scheduler_schedulers"
  end

  test "coerces boolean extras to 1/0 and includes numeric extras" do
    output = AppStatus.PrometheusFormatter.format(@report)

    assert output =~
             "app_status_extra_db_pool_checked_out{app=\"my_app\",node=\"my_app@localhost\"} 3"

    assert output =~ "app_status_extra_ibkr_connected{app=\"my_app\",node=\"my_app@localhost\"} 1"
    assert output =~ "app_status_extra_sync_ok{app=\"my_app\",node=\"my_app@localhost\"} 0"
  end

  test "skips string extras since Prometheus gauges can't represent them" do
    output = AppStatus.PrometheusFormatter.format(@report)

    refute output =~ "app_status_extra_region"
  end
end
