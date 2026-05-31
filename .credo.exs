# Credo configuration for bot_army_para
# Suppressions are temporary - issues should be fixed in follow-up tasks

%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        excluded: []
      },
      checks: [
        {Credo.Check.Design.AliasUsage,
         [
           excluded_namespaces: [BotArmyPara.PulsePublisher],
           excluded_paths: ["lib/bot_army_para/pulse_publisher.ex"]
         ]},
        {Credo.Check.Readability.ImplicitTry,
         [
           excluded_paths: [
             "lib/bot_army_para/skills/example.ex",
             "test/bot_army_para/example_test.exs"
           ]
         ]}
      ]
    }
  ]
}
