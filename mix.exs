defmodule AppStatus.MixProject do
  use Mix.Project

  @version "0.1.1"

  def project do
    [
      app: :app_status,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Shared /status + /status/metrics reporting for Elixir/Phoenix apps",
      package: package()
    ]
  end

  # Because this app has a `mod:` entry below, OTP automatically starts
  # AppStatus.Application (and therefore the Collector GenServer) as soon
  # as this dependency is loaded by a host app — no wiring needed in the
  # host app's own application.ex.
  def application do
    [
      mod: {AppStatus.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:plug, "~> 1.14"},
      {:jason, "~> 1.4"}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{}
    ]
  end
end
