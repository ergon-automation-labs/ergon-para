import Config

# Runtime configuration — evaluated at boot, not compile time.
# Release builds bake config.exs into sys.config with the build host's env;
# on a clean build host NATS_PORT is unset, so the baked value falls back to
# the dev broker (4223) and the bot silently runs detached from production.
# This block mirrors llm/sre's runtime.exs (ConfigLoader reads env at boot).
if config_env() != :test do
  nats_host = BotArmyLibraryRuntime.ConfigLoader.get("NATS_HOST", "localhost")

  nats_port =
    BotArmyLibraryRuntime.ConfigLoader.get("NATS_PORT", "4223") |> String.to_integer()

  config :bot_army_library_runtime, :nats,
    servers: [{nats_host, nats_port}],
    ping_interval: 30_000,
    max_reconnect_attempts: 10,
    reconnect_delay_ms: 1000
end
