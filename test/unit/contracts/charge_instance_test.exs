defmodule BillingCore.Contracts.ChargeInstanceTest do
  @moduledoc """
  One-time charge instance creation rules (BC-US-041, SPEC §13.3
  `charge_instances`): exactly one pricing source, contract currency only,
  explicit recognition policy, idempotent replays, and cancellation only
  while pending.
  """

  use BillingCore.DataCase, async: true

  alias BillingCore.Contracts
  alias BillingCore.Contracts.ChargeInstance
  alias BillingCore.Outbox

  import BillingCore.ContractsFixtures

  setup do
    scope = billing_scope_fixture()
    today = Date.utc_today()
    contract = contract_fixture(scope, %{currency: "DKK", start_date: Date.add(today, -100)})
    %{scope: scope, contract: contract, today: today}
  end

  describe "pricing source (exactly one is authoritative)" do
    test "a published price component with a positive quantity", ctx do
      price_component_id = Ecto.UUID.generate()

      assert {:ok, charge} =
               Contracts.create_charge_instance(
                 ctx.scope,
                 valid_charge_instance_attrs(ctx.contract, %{
                   price_component_id: price_component_id,
                   quantity: Decimal.new(3)
                 })
               )

      assert charge.status == :pending
      assert charge.price_component_id == price_component_id
      assert charge.amount_minor == nil
      assert Decimal.eq?(charge.quantity, 3)
      assert charge.currency == "DKK"
      assert charge.payload_hash =~ ~r/^[0-9a-f]{64}$/
      assert charge.canonical_payload["external_id"] == charge.external_id
      assert "charge_instance.created.v1" in outbox_events(charge.id)
    end

    test "an explicit amount fixes the quantity at 1", ctx do
      assert {:ok, charge} =
               Contracts.create_charge_instance(
                 ctx.scope,
                 valid_charge_instance_attrs(ctx.contract, %{amount_minor: 12_500})
               )

      assert charge.amount_minor == 12_500
      assert charge.price_component_id == nil
      assert Decimal.eq?(charge.quantity, 1)
    end

    test "an explicit amount with quantity other than 1 is rejected", ctx do
      assert {:error, :invalid_quantity} =
               Contracts.create_charge_instance(
                 ctx.scope,
                 valid_charge_instance_attrs(ctx.contract, %{amount_minor: 12_500, quantity: 5})
               )
    end

    test "both pricing sources at once are rejected", ctx do
      assert {:error, :ambiguous_pricing_source} =
               Contracts.create_charge_instance(
                 ctx.scope,
                 valid_charge_instance_attrs(ctx.contract, %{
                   price_component_id: Ecto.UUID.generate(),
                   amount_minor: 100
                 })
               )
    end

    test "no pricing source is rejected", ctx do
      attrs =
        ctx.contract
        |> valid_charge_instance_attrs()
        |> Map.drop([:price_component_id, :quantity])

      assert {:error, :missing_pricing_source} =
               Contracts.create_charge_instance(ctx.scope, attrs)
    end

    test "negative explicit amounts are rejected — corrections, not negatives", ctx do
      assert {:error, :negative_amount} =
               Contracts.create_charge_instance(
                 ctx.scope,
                 valid_charge_instance_attrs(ctx.contract, %{amount_minor: -100})
               )
    end

    test "a non-positive quantity is rejected", ctx do
      assert {:error, :invalid_quantity} =
               Contracts.create_charge_instance(
                 ctx.scope,
                 valid_charge_instance_attrs(ctx.contract, %{quantity: 0})
               )
    end
  end

  describe "currency (one contract, one currency)" do
    test "a currency differing from the contract is rejected", ctx do
      assert {:error, :currency_mismatch} =
               Contracts.create_charge_instance(
                 ctx.scope,
                 valid_charge_instance_attrs(ctx.contract, %{currency: "EUR"})
               )
    end

    test "the currency defaults to the contract currency", ctx do
      {:ok, charge} =
        Contracts.create_charge_instance(ctx.scope, valid_charge_instance_attrs(ctx.contract))

      assert charge.currency == "DKK"
    end
  end

  describe "recognition mode" do
    test "over_time requires a half-open service period", ctx do
      attrs = valid_charge_instance_attrs(ctx.contract, %{recognition_mode: :over_time})

      assert {:error, changeset} = Contracts.create_charge_instance(ctx.scope, attrs)
      assert %{service_start: [_message]} = errors_on(changeset)

      # inverted period rejected
      assert {:error, changeset} =
               Contracts.create_charge_instance(
                 ctx.scope,
                 Map.merge(attrs, %{
                   service_start: ctx.today,
                   service_end_exclusive: ctx.today
                 })
               )

      assert %{service_end_exclusive: [_message]} = errors_on(changeset)

      # a valid half-open period is accepted
      assert {:ok, charge} =
               Contracts.create_charge_instance(
                 ctx.scope,
                 Map.merge(attrs, %{
                   service_start: ctx.today,
                   service_end_exclusive: Date.add(ctx.today, 30)
                 })
               )

      assert charge.recognition_mode == :over_time
    end

    test "point_in_time must not carry a service period", ctx do
      assert {:error, changeset} =
               Contracts.create_charge_instance(
                 ctx.scope,
                 valid_charge_instance_attrs(ctx.contract, %{
                   recognition_mode: :point_in_time,
                   service_start: ctx.today,
                   service_end_exclusive: Date.add(ctx.today, 30)
                 })
               )

      assert %{service_start: [_message]} = errors_on(changeset)
    end

    test "the recognition-mode CHECK is enforced at the database", ctx do
      # bypass the context/changeset entirely: over_time without a period
      assert_raise Postgrex.Error, ~r/charge_instances_recognition_check/, fn ->
        Repo.insert_all(ChargeInstance, [
          %{
            id: Ecto.UUID.generate(),
            team_id: ctx.scope.team.id,
            external_id: unique_charge_external_id(),
            contract_id: ctx.contract.id,
            product_id: Ecto.UUID.generate(),
            product_version: 1,
            status: :pending,
            eligible_on: ctx.today,
            quantity: Decimal.new(1),
            currency: "DKK",
            recognition_mode: :over_time,
            canonical_payload: %{},
            payload_hash: "test"
          }
        ])
      end
    end
  end

  describe "idempotent replay by external charge ID" do
    test "an identical canonical replay returns the original charge", ctx do
      attrs = valid_charge_instance_attrs(ctx.contract, %{external_id: "chg-replay-1"})

      assert {:ok, original} = Contracts.create_charge_instance(ctx.scope, attrs)
      assert {:ok, replayed} = Contracts.create_charge_instance(ctx.scope, attrs)

      assert replayed.id == original.id
      assert Repo.aggregate(ChargeInstance, :count) == 1
    end

    test "a different payload for the same external ID is a conflict", ctx do
      attrs = valid_charge_instance_attrs(ctx.contract, %{external_id: "chg-replay-2"})

      assert {:ok, _original} = Contracts.create_charge_instance(ctx.scope, attrs)

      assert {:error, :conflict} =
               Contracts.create_charge_instance(
                 ctx.scope,
                 Map.put(attrs, :eligible_on, Date.add(ctx.today, 1))
               )
    end
  end

  describe "association rules" do
    test "a subscription must belong to the same contract and team", ctx do
      subscription = subscription_fixture(ctx.scope, %{contract_id: ctx.contract.id})

      assert {:ok, charge} =
               Contracts.create_charge_instance(
                 ctx.scope,
                 valid_charge_instance_attrs(ctx.contract, %{subscription_id: subscription.id})
               )

      assert charge.subscription_id == subscription.id

      other_contract = contract_fixture(ctx.scope, %{start_date: Date.add(ctx.today, -100)})

      assert {:error, :subscription_not_in_contract} =
               Contracts.create_charge_instance(
                 ctx.scope,
                 valid_charge_instance_attrs(other_contract, %{subscription_id: subscription.id})
               )
    end

    test "the contract must belong to the scope's team", ctx do
      other_scope = billing_scope_fixture()

      assert {:error, :contract_not_found} =
               Contracts.create_charge_instance(
                 other_scope,
                 valid_charge_instance_attrs(ctx.contract)
               )
    end
  end

  describe "cancellation (only before freezing into invoice intent)" do
    test "a pending charge can be cancelled exactly once", ctx do
      charge = charge_instance_fixture(ctx.scope, ctx.contract)

      assert {:ok, cancelled} =
               Contracts.cancel_charge_instance(ctx.scope, charge, %{reason: "mistake"})

      assert cancelled.status == :cancelled
      assert "charge_instance.cancelled.v1" in outbox_events(charge.id)

      assert {:error, :not_pending} = Contracts.cancel_charge_instance(ctx.scope, cancelled)
    end

    test "a frozen charge cannot be cancelled", ctx do
      charge = charge_instance_fixture(ctx.scope, ctx.contract)

      # simulate the billing engine freezing the charge into invoice intent
      Repo.update_all(
        from(c in ChargeInstance, where: c.id == ^charge.id),
        set: [status: "frozen"]
      )

      assert {:error, :not_pending} = Contracts.cancel_charge_instance(ctx.scope, charge)
    end

    test "creation and cancellation require billing roles", ctx do
      charge = charge_instance_fixture(ctx.scope, ctx.contract)
      auditor = team_scope_fixture(ctx.scope.organization, ctx.scope.team, [:auditor])

      assert {:error, :unauthorized} =
               Contracts.create_charge_instance(
                 auditor,
                 valid_charge_instance_attrs(ctx.contract)
               )

      assert {:error, :unauthorized} = Contracts.cancel_charge_instance(auditor, charge)
      assert {:ok, %{id: id}} = Contracts.get_charge_instance(auditor, charge.id)
      assert id == charge.id
    end
  end

  defp outbox_events(aggregate_id) do
    Repo.all(from e in Outbox.Event, where: e.aggregate_id == ^aggregate_id, select: e.event_type)
  end
end
