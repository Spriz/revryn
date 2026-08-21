defmodule BillingCore.Repo do
  use Ecto.Repo,
    otp_app: :billing_core,
    adapter: Ecto.Adapters.Postgres
end
