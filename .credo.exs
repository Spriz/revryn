# Credo gate for CI (`mix credo`, also part of `mix precommit`).
#
# CyclomaticComplexity stays at the Credo default (9): complex functions
# get decomposed into simple, flat helpers — plain repetition beats clever
# indirection here. Nesting is raised 2 → 3 only because idiomatic
# Phoenix/Ecto code (with → case → if) routinely sits at 3; anything
# deeper gets flattened into helpers.
%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "config/", "test/"],
        excluded: [~r"/_build/", ~r"/deps/", ~r"/node_modules/"]
      },
      strict: false,
      checks: %{
        extra: [
          {Credo.Check.Refactor.Nesting, max_nesting: 3}
        ]
      }
    }
  ]
}
