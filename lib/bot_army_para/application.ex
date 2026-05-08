defmodule BotArmyPara.Application do
  @moduledoc """
  Para Bot application supervisor.

  Follows bot army pattern with environment-aware startup:
  - Repo not started in :test (tests inject mocks)
  - PulsePublisher sends `system.health` liveness every 30s and rich `bot.<service>.pulse` every 30 minutes
  - Workers not started in :test (gated by @env)

  Observability: see `PulsePublisher` — fleet UIs keyed on Synapse hydration should use `system.health` freshness (90s), not pulse interval alone.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children =
      []
      |> add_pulse_publisher()
      |> add_workers()

    opts = [strategy: :one_for_one, name: BotArmyPara.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp add_pulse_publisher(children), do: [{BotArmyPara.PulsePublisher, []} | children]

  defp add_workers(children), do: [{BotArmyPara.NATS.Consumer, []} | children]
end
