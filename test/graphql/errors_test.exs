defmodule BillingCoreWeb.GraphQL.ErrorsTest do
  @moduledoc """
  Typed mutation problems and stable error codes (SPEC §14.4): every domain
  `{:error, reason}` maps to a stable, client-handleable problem value —
  never a free-form string, never internals.
  """

  use ExUnit.Case, async: true

  alias BillingCoreWeb.GraphQL.Errors

  describe "problem constructors" do
    test "validation/4 defaults and explicit arguments" do
      assert Errors.validation("CODE", "msg") ==
               %{
                 __problem__: :validation,
                 code: "CODE",
                 message: "msg",
                 fields: [],
                 client_mutation_id: nil
               }

      fields = [%{path: ["x"], code: "INVALID", message: "bad"}]

      assert Errors.validation("CODE", "msg", fields, "cmid-1") ==
               %{
                 __problem__: :validation,
                 code: "CODE",
                 message: "msg",
                 fields: fields,
                 client_mutation_id: "cmid-1"
               }
    end

    test "mapping/4 tags the problem as :mapping" do
      assert %{__problem__: :mapping, code: "BLOCKED", fields: [], client_mutation_id: nil} =
               Errors.mapping("BLOCKED", "blocked")
    end

    test "authorization/1 carries a stable code and message" do
      assert %{
               __problem__: :authorization,
               code: "UNAUTHORIZED",
               client_mutation_id: "cmid-2"
             } = Errors.authorization("cmid-2")

      assert Errors.authorization().client_mutation_id == nil
    end

    test "version_conflict/3 carries both versions" do
      assert Errors.version_conflict(3, 5, "cmid-3") ==
               %{
                 __problem__: :version_conflict,
                 expected_version: 3,
                 actual_version: 5,
                 client_mutation_id: "cmid-3"
               }

      assert Errors.version_conflict(1, 2).client_mutation_id == nil
    end

    test "idempotency_conflict/1 carries the stable reuse code" do
      assert %{__problem__: :idempotency, code: "IDEMPOTENCY_KEY_REUSED"} =
               Errors.idempotency_conflict()
    end
  end

  describe "changeset_fields/1" do
    test "flattens errors into per-field paths with interpolated messages" do
      types = %{name: :string, email: :string}

      changeset =
        {%{}, types}
        |> Ecto.Changeset.cast(%{"email" => "x"}, Map.keys(types))
        |> Ecto.Changeset.validate_required([:name])
        |> Ecto.Changeset.validate_length(:email, min: 3)

      fields = Errors.changeset_fields(changeset)

      assert %{path: ["name"], code: "INVALID", message: "can't be blank"} in fields
      # `%{count}` is interpolated from the validation opts.
      assert %{path: ["email"], code: "INVALID", message: "should be at least 3 character(s)"} in fields

      assert length(fields) == 2
    end
  end

  describe "business_error/2 mapping table" do
    test ":unauthorized maps to the authorization problem" do
      assert %{__problem__: :authorization, code: "UNAUTHORIZED", client_mutation_id: "c"} =
               Errors.business_error(:unauthorized, "c")
    end

    test ":idempotency_key_reused maps to the idempotency conflict" do
      assert %{__problem__: :idempotency, code: "IDEMPOTENCY_KEY_REUSED"} =
               Errors.business_error(:idempotency_key_reused)
    end

    test "a changeset maps to VALIDATION_FAILED with its field problems" do
      changeset =
        {%{}, %{code: :string}}
        |> Ecto.Changeset.cast(%{}, [:code])
        |> Ecto.Changeset.validate_required([:code])

      assert %{
               __problem__: :validation,
               code: "VALIDATION_FAILED",
               fields: [%{path: ["code"], code: "INVALID", message: "can't be blank"}],
               client_mutation_id: "cmid"
             } = Errors.business_error(changeset, "cmid")
    end

    test ":conflict maps to the external-identifier CONFLICT validation" do
      assert %{__problem__: :validation, code: "CONFLICT"} = Errors.business_error(:conflict)
    end

    test "{:blocked, blockers} maps each blocker into a mapping problem" do
      blockers = [
        {:metered_component, "api_calls"},
        {:rating_failed, "seats", :missing_rate},
        {:product_mapping_missing, "prod-1"},
        {:customer_mapping_missing, "cust-1"}
      ]

      assert %{__problem__: :mapping, code: "BLOCKED", fields: fields} =
               Errors.business_error({:blocked, blockers}, nil)

      assert Enum.map(fields, & &1.code) == [
               "METERED_COMPONENT",
               "RATING_FAILED",
               "PRODUCT_MAPPING_MISSING",
               "CUSTOMER_MAPPING_MISSING"
             ]

      assert Enum.all?(fields, &(&1.path == []))
    end

    test "{:illegal_state, detail} maps to ILLEGAL_STATE without leaking detail" do
      problem = Errors.business_error({:illegal_state, {:from, :booked}}, nil)

      assert %{__problem__: :validation, code: "ILLEGAL_STATE", fields: []} = problem
      refute inspect(problem) =~ "booked"
    end

    test "{:invalid_pricing_definition, reasons} maps reasons under pricingDefinition" do
      assert %{
               __problem__: :validation,
               code: "INVALID_PRICING_DEFINITION",
               fields: [
                 %{path: ["pricingDefinition"], code: "INVALID", message: "negative_rate"},
                 %{path: ["pricingDefinition"], code: "INVALID", message: "overlapping tiers"}
               ]
             } =
               Errors.business_error(
                 {:invalid_pricing_definition, [:negative_rate, "overlapping tiers"]},
                 nil
               )

      # A single (non-list) reason is wrapped.
      assert %{fields: [%{message: "negative_rate"}]} =
               Errors.business_error({:invalid_pricing_definition, :negative_rate}, nil)
    end

    test "{:invalid_pricing_definition, code, reasons} maps under the component code" do
      assert %{
               __problem__: :validation,
               code: "INVALID_PRICING_DEFINITION",
               fields: [%{path: ["components", "seats"], code: "INVALID", message: "bad_tier"}]
             } = Errors.business_error({:invalid_pricing_definition, :seats, :bad_tier}, nil)
    end

    test "a bare atom reason becomes an upcased stable code" do
      assert %{
               __problem__: :validation,
               code: "NOT_PREVIEWABLE",
               message: "the command was rejected: not_previewable"
             } = Errors.business_error(:not_previewable)
    end

    test "an unmatched tuple reason falls back to its leading atom" do
      assert %{__problem__: :validation, code: "FROZEN"} =
               Errors.business_error({:frozen, "intent already frozen"}, nil)
    end

    test "anything else becomes the generic REJECTED validation" do
      assert %{__problem__: :validation, code: "REJECTED", message: "the command was rejected"} =
               Errors.business_error("stack trace or whatever", nil)
    end
  end

  describe "blocker rendering" do
    test "blocker_code/1 covers every clause" do
      assert Errors.blocker_code({:metered_component, "api"}) == "METERED_COMPONENT"
      assert Errors.blocker_code({:rating_failed, "api", :oops}) == "RATING_FAILED"
      assert Errors.blocker_code({:product_mapping_missing, "p1"}) == "PRODUCT_MAPPING_MISSING"
      assert Errors.blocker_code({:customer_mapping_missing, "c1"}) == "CUSTOMER_MAPPING_MISSING"
      assert Errors.blocker_code(:no_erp_connection) == "NO_ERP_CONNECTION"
      assert Errors.blocker_code({:weird_thing, 1, 2, 3}) == "WEIRD_THING"
      assert Errors.blocker_code("free text") == "BLOCKED"
    end

    test "blocker_message/1 renders stable human-readable text" do
      assert Errors.blocker_message({:metered_component, "api"}) ==
               "metered component api not previewable"

      assert Errors.blocker_message({:rating_failed, "api", :secret_reason}) ==
               "rating failed for component api"

      # The failure reason never leaks into the message.
      refute Errors.blocker_message({:rating_failed, "api", :secret_reason}) =~ "secret"

      assert Errors.blocker_message({:product_mapping_missing, "p1"}) ==
               "product p1 has no ERP mapping"

      assert Errors.blocker_message({:customer_mapping_missing, "c1"}) ==
               "customer c1 has no ERP mapping"

      # Fallback stringification: binary, atom, {atom, detail} tuple, inspect.
      assert Errors.blocker_message("free text") == "free text"
      assert Errors.blocker_message(:no_erp_connection) == "no_erp_connection"
      assert Errors.blocker_message({:missing, :mapping}) == "missing:mapping"
      assert Errors.blocker_message(%{odd: true}) == inspect(%{odd: true})
    end

    test "blocker_string/1 renders CODE or CODE:detail" do
      assert Errors.blocker_string({:metered_component, "api"}) == "METERED_COMPONENT:api"
      assert Errors.blocker_string({:rating_failed, "api", :oops}) == "RATING_FAILED:api"

      assert Errors.blocker_string({:product_mapping_missing, "p1"}) ==
               "PRODUCT_MAPPING_MISSING:p1"

      assert Errors.blocker_string({:customer_mapping_missing, "c1"}) ==
               "CUSTOMER_MAPPING_MISSING:c1"

      assert Errors.blocker_string(:no_erp_connection) == "NO_ERP_CONNECTION"
    end
  end

  describe "resolve_union/2" do
    test "dispatches every problem tag and falls back to the success type" do
      assert Errors.resolve_union(%{__problem__: :validation}, :ok_type) == :validation_problem
      assert Errors.resolve_union(%{__problem__: :mapping}, :ok_type) == :mapping_problem

      assert Errors.resolve_union(%{__problem__: :authorization}, :ok_type) ==
               :authorization_problem

      assert Errors.resolve_union(%{__problem__: :version_conflict}, :ok_type) ==
               :version_conflict

      assert Errors.resolve_union(%{__problem__: :idempotency}, :ok_type) ==
               :idempotency_conflict

      assert Errors.resolve_union(%{id: "success-row"}, :customer_payload) == :customer_payload
    end
  end

  describe "query-side errors" do
    test "query_error/2 and the stable shortcuts" do
      assert Errors.query_error("CODE", "msg") == {:error, %{message: "msg", code: "CODE"}}

      assert Errors.unauthenticated() ==
               {:error, %{message: "authentication required", code: "UNAUTHENTICATED"}}

      assert Errors.unauthorized() ==
               {:error,
                %{message: "not authorized for the requested scope", code: "UNAUTHORIZED"}}

      assert Errors.not_found() ==
               {:error,
                %{message: "resource not found in the requested scope", code: "NOT_FOUND"}}
    end
  end
end
