defmodule AppStatus do
  @moduledoc """
  Shared BEAM/Phoenix `/status` reporting, mountable in any host app.

  Quick start in a host app:

      # mix.exs
      {:app_status, git: "https://github.com/semdinsp/app_status.git", tag: "v0.1.1"}

      # config/config.exs
      config :app_status,
        app_name: :my_app,
        endpoint: MyAppWeb.Endpoint

      # router.ex
      forward "/status", AppStatus.Plug

  See `AppStatus.Extension` for adding app-specific metrics (DB pool
  stats, external connection health, etc.) to the report.
  """
end
