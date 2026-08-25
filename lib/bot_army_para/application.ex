defmodule BotArmyPara.Application do
  @moduledoc """
  Para Bot application supervisor.

  Follows bot army pattern with environment-aware startup:
  - Repo not started in :test (tests inject mocks)
  - PulsePublisher sends `system.health` liveness every 30s and rich `bot.<service>.pulse` every 30 minutes
  - Workers not started in :test (gated by @env)
  - LeaderElection coordinates dual-node (air/mini) deployment: air primary answers base subjects,
    mini standby waits and watches heartbeat, auto-failover on heartbeat timeout

  Observability: see `PulsePublisher` — fleet UIs keyed on Synapse hydration should use `system.health` freshness (90s), not pulse interval alone.
  """

  use Application

  @env Mix.env()

  @impl true
  def start(_type, _args) do
    children =
      []
      |> add_pulse_publisher()
      |> add_leader_election()
      |> add_workers()

    opts = [strategy: :one_for_one, name: BotArmyPara.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp add_pulse_publisher(children), do: [{BotArmyPara.PulsePublisher, []} | children]

  defp add_leader_election(children) do
    if @env == :test do
      children
    else
      [
        {BotArmyLibraryRuntime.LeaderElection,
         service: "para",
         node_name: System.get_env("NODE_NAME", "unknown"),
         default_role: BotArmyLibraryRuntime.LeaderElection.role_from_env("PARA_NODE_ROLE"),
         on_role_change: {BotArmyPara.NATS.Consumer, :leader_role_changed, []}}
        | children
      ]
    end
  end

  defp add_workers(children) do
    if @env == :test do
      children
    else
      [{BotArmyPara.NATS.Consumer, []} | children]
    end
  end
end
