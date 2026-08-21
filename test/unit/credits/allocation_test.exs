defmodule BillingCore.Credits.AllocationTest do
  @moduledoc """
  Property coverage for deterministic credit allocation (INV-052) and the
  ledger-sum invariant: `available + reserved` always equals the sum of
  grant remainders, and the projections always reconcile to the ledger.
  """

  use BillingCore.DataCase, async: true
  use ExUnitProperties

  alias BillingCore.Credits
  alias BillingCore.Credits.{CreditAccount, CreditGrant}
  alias BillingCore.OrgsFixtures

  import BillingCore.CreditsFixtures

  @day 86_400

  describe "allocate/2 (pure)" do
    property "consumes grants strictly in the given order and totals the request" do
      check all(
              headrooms <- list_of(integer(1..500), min_length: 1, max_length: 8),
              fraction <- integer(1..100)
            ) do
        grants = pure_grants(headrooms)
        total = Enum.sum(headrooms)
        requested = max(div(total * fraction, 100), 1)

        assert {:ok, allocations} = Credits.allocate(grants, requested)

        # totals exactly the requested amount
        assert allocations |> Enum.map(&elem(&1, 1)) |> Enum.sum() == requested

        # never exceeds a grant's headroom
        assert Enum.all?(allocations, fn {grant, amount} ->
                 amount > 0 and amount <= CreditGrant.headroom(grant)
               end)

        # consumes a strict prefix of the given order: every allocated grant
        # except the last is fully drained before the next one is touched
        allocated_ids = Enum.map(allocations, fn {grant, _} -> grant.id end)
        prefix_ids = grants |> Enum.take(length(allocations)) |> Enum.map(& &1.id)
        assert allocated_ids == prefix_ids

        {full, [_last]} = Enum.split(allocations, -1)
        assert Enum.all?(full, fn {grant, amount} -> amount == CreditGrant.headroom(grant) end)
      end
    end

    property "over-allocation always fails without partial results" do
      check all(
              headrooms <- list_of(integer(1..500), min_length: 1, max_length: 8),
              excess <- integer(1..100)
            ) do
        grants = pure_grants(headrooms)

        assert {:error, :insufficient_credit} =
                 Credits.allocate(grants, Enum.sum(headrooms) + excess)
      end
    end
  end

  describe "reserve/5 against the ledger" do
    setup do
      credit_context_fixture()
    end

    property "reservations consume grants in expiry order and reconcile", ctx do
      check all(
              specs <-
                list_of(
                  {integer(1..500), one_of([constant(nil), integer(1..60)])},
                  min_length: 1,
                  max_length: 5
                ),
              fraction <- integer(1..120),
              max_runs: 15
            ) do
        now = DateTime.utc_now()
        account = fresh_credit_account(ctx)

        grants =
          Enum.map(specs, fn {amount, expiry_days} ->
            grant_fixture(ctx.scope, account, %{
              amount_minor: amount,
              expires_at: expiry_days && DateTime.add(now, expiry_days * @day, :second)
            })
          end)

        total = specs |> Enum.map(&elem(&1, 0)) |> Enum.sum()
        requested = max(div(total * fraction, 100), 1)

        expected =
          case Credits.allocate(expiry_order(grants), requested) do
            {:ok, allocations} -> {:ok, Enum.map(allocations, fn {g, a} -> {g.id, a} end)}
            error -> error
          end

        result = Credits.reserve(:system, account, requested, "prop-#{account.id}")

        case expected do
          {:ok, allocations} ->
            # the DB reservation matches the pure earliest-expiry allocation
            assert result == {:ok, allocations}
            assert_ledger_sum(account)
            assert Credits.reconcile_account(account.id) == :ok

          {:error, :insufficient_credit} ->
            assert result == {:error, :insufficient_credit}
            assert_ledger_sum(account)
        end
      end
    end

    property "available + reserved equals the grant remainders across mixed operations", ctx do
      check all(
              specs <-
                list_of(
                  {integer(50..300), one_of([constant(nil), integer(1..30)])},
                  min_length: 1,
                  max_length: 4
                ),
              steps <- list_of({integer(1..150), member_of([:apply, :release])}, max_length: 4),
              max_runs: 15
            ) do
        now = DateTime.utc_now()
        account = fresh_credit_account(ctx)

        Enum.each(specs, fn {amount, expiry_days} ->
          grant_fixture(ctx.scope, account, %{
            amount_minor: amount,
            expires_at: expiry_days && DateTime.add(now, expiry_days * @day, :second)
          })
        end)

        assert_ledger_sum(account)

        steps
        |> Enum.with_index()
        |> Enum.each(fn {{amount, outcome}, index} ->
          key = "step-#{account.id}-#{index}"

          case Credits.reserve(:system, account, amount, key) do
            {:error, :insufficient_credit} ->
              :ok

            {:ok, allocations} ->
              case outcome do
                :apply ->
                  {:ok, _} = Credits.apply_reservation(:system, account, allocations, key <> "-a")

                :release ->
                  {:ok, _} = Credits.release(:system, account, key, key <> "-r")
              end
          end

          assert_ledger_sum(account)
        end)

        assert Credits.reconcile_account(account.id) == :ok
      end
    end
  end

  # A pure in-memory grant list in allocation order, for `allocate/2`.
  defp pure_grants(headrooms) do
    headrooms
    |> Enum.with_index()
    |> Enum.map(fn {headroom, index} ->
      %CreditGrant{
        id: Ecto.UUID.generate(),
        remaining_minor: headroom,
        reserved_minor: 0,
        granted_minor: headroom,
        granted_at: DateTime.utc_now(),
        currency: "DKK",
        status: :available,
        metadata: %{"index" => index}
      }
    end)
  end

  # INV-052 ordering: earliest expiry first (nulls last), oldest grant, id.
  defp expiry_order(grants) do
    Enum.sort_by(grants, fn grant ->
      {
        if(grant.expires_at, do: 0, else: 1),
        grant.expires_at && DateTime.to_unix(grant.expires_at, :microsecond),
        DateTime.to_unix(grant.granted_at, :microsecond),
        grant.id
      }
    end)
  end

  defp fresh_credit_account(ctx) do
    org_account = OrgsFixtures.account_fixture(ctx.organization)
    credit_account_fixture(ctx.scope, org_account)
  end

  defp assert_ledger_sum(account) do
    reloaded = Repo.get!(CreditAccount, account.id)

    remainder_sum =
      Repo.one(
        from g in CreditGrant,
          where: g.credit_account_id == ^account.id,
          select: type(coalesce(sum(g.remaining_minor), 0), :integer)
      )

    assert reloaded.available_minor + reloaded.reserved_minor == remainder_sum
    assert reloaded.available_minor >= 0
    assert reloaded.reserved_minor >= 0
  end
end
