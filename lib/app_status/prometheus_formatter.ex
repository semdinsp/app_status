defmodule AppStatus.PrometheusFormatter do
  @moduledoc """
  Converts the AppStatus report map into Prometheus text exposition
  format, so Prometheus/Grafana can scrape `/status/metrics` directly —
  no PromEx or extra dependency required. If you later want richer
  histograms (request duration percentiles, etc.) via `:telemetry`,
  swap this out for PromEx; this formatter covers gauges/counters for
  everything AppStatus.Report already gathers.
  """

  @app_prefix "app_status"

  @doc "Renders a report map as a Prometheus text exposition payload."
  @spec format(map()) :: String.t()
  def format(report) do
    labels = "app=\"#{report.app}\",node=\"#{report.node}\""

    lines =
      [
        gauge("uptime_seconds", report.uptime_seconds, labels, "Process uptime in seconds"),
        memory_lines(report.memory, labels),
        process_lines(report.process, labels),
        scheduler_lines(report.scheduler, labels),
        extra_lines(report.extra, labels)
      ]
      |> List.flatten()

    Enum.join(lines, "\n") <> "\n"
  end

  defp memory_lines(memory, labels) do
    Enum.map(memory, fn {key, value} ->
      gauge("memory_#{key}_bytes", value, labels, "BEAM memory: #{key}")
    end)
  end

  defp process_lines(process, labels) do
    Enum.map(process, fn {key, value} ->
      gauge("process_#{key}", value, labels, "BEAM process/port/atom stat: #{key}")
    end)
  end

  defp scheduler_lines(scheduler, labels) do
    Enum.map(scheduler, fn {key, value} ->
      gauge("scheduler_#{key}", value, labels, "Scheduler stat: #{key}")
    end)
  end

  # Only numeric values from the host app's extension are exported as
  # metrics (Prometheus can't represent strings/booleans as gauges
  # directly). Booleans are coerced to 1/0 since that's the Prometheus
  # convention for up/down-style values.
  defp extra_lines(extra, labels) when is_map(extra) do
    Enum.flat_map(extra, fn
      {key, value} when is_number(value) ->
        [gauge("extra_#{key}", value, labels, "Host app metric: #{key}")]

      {key, true} ->
        [gauge("extra_#{key}", 1, labels, "Host app metric: #{key}")]

      {key, false} ->
        [gauge("extra_#{key}", 0, labels, "Host app metric: #{key}")]

      _ ->
        []
    end)
  end

  defp extra_lines(_, _), do: []

  defp gauge(name, value, labels, help) do
    metric = "#{@app_prefix}_#{name}"

    """
    # HELP #{metric} #{help}
    # TYPE #{metric} gauge
    #{metric}{#{labels}} #{format_value(value)}\
    """
  end

  defp format_value(value) when is_integer(value), do: value
  defp format_value(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 4)
  defp format_value(_), do: 0
end
