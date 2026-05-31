# Credo configuration for bot_army_para
# Suppressions are temporary - issues should be fixed in follow-up tasks

%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        excluded: [
          "lib/bot_army_para/skills/example.ex",
          "test/bot_army_para/example_test.exs"
        ]
      },
      checks: [
        {Credo.Check.Design.AliasUsage, false},
        {Credo.Check.Refactor.CaseTrivialMatches, false}
      ]
    }
  ]
}
