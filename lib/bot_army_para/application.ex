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
    # Load configuration from Salt-deployed config file (not env vars)
    # This fixes macOS launchd environment variable pass-through limitation
    config_data = BotArmyLibraryRuntime.ConfigLoader.load_config()
    Application.put_env(:bot_army_library_runtime, :config_data, config_data)

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
      role_str = BotArmyLibraryRuntime.ConfigLoader.get("PARA_NODE_ROLE", "primary")
      role = parse_role(role_str)

      [
        {BotArmyLibraryRuntime.LeaderElection,
         service: "para",
         node_name: BotArmyLibraryRuntime.ConfigLoader.get("NODE_NAME", "unknown"),
         default_role: role,
         on_role_change: {BotArmyPara.NATS.Consumer, :leader_role_changed, []}}
        | children
      ]
    end
  end

  defp parse_role("standby"), do: :standby
  defp parse_role("primary"), do: :primary
  defp parse_role(_), do: :primary

  defp add_workers(children) do
    if @env == :test do
      children
    else
      [{BotArmyPara.NATS.Consumer, []} | children]
    end
  end
end
