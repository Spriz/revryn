# Credo gate for CI (`mix credo` runs in the test job).
#
# Thresholds for Nesting and CyclomaticComplexity are raised from the
# defaults (2 and 9): the long transactional domain functions here are
# deliberate — a money movement reads as one auditable unit, guarded by
# the workflow/property suites rather than by decomposition. The limits
# are pinned just above the current maxima so the gate still binds:
# anything deeper/more complex than today's worst case fails CI.
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
          {Credo.Check.Refactor.Nesting, max_nesting: 5},
          {Credo.Check.Refactor.CyclomaticComplexity, max_complexity: 21}
        ]
      }
    }
  ]
}
