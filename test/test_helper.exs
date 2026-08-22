# Performance and soak suites are capacity evidence, not CI gates: run them
# on demand with `mix test --only performance` / `--only soak`
# (docs/reviews/capacity-v1.md records the accepted numbers).
ExUnit.start(exclude: [:performance, :soak])
Ecto.Adapters.SQL.Sandbox.mode(BillingCore.Repo, :manual)
