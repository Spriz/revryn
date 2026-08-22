defmodule BillingCoreWeb.GraphQL.ContextTest do
  @moduledoc """
  Transport-level context construction and document limits (SPEC §14.2/§14.7):
  bearer authentication resolves the principal, correlation IDs propagate
  only when valid UUIDs, and oversized documents are rejected pre-parse.
  """

  use BillingCore.DataCase, async: true

  import BillingCore.IdentityFixtures

  alias BillingCore.Identity
  alias BillingCoreWeb.GraphQL.Context

  @opts Context.init([])

  defp run(params, headers \\ []) do
    conn = Plug.Test.conn(:post, "/graphql", params)

    headers
    |> Enum.reduce(conn, fn {key, value}, conn ->
      Plug.Conn.put_req_header(conn, key, value)
    end)
    |> Context.call(@opts)
  end

  defp context(conn), do: conn.private.absinthe.context

  describe "authentication" do
    test "a valid bearer session token resolves the current user" do
      user = user_fixture()
      {token, _session} = Identity.create_session(user)

      conn = run(%{"query" => "{ apiVersion }"}, [{"authorization", "Bearer #{token}"}])

      refute conn.halted
      assert context(conn).current_user.id == user.id
    end

    test "an invalid bearer token yields an unauthenticated context" do
      conn = run(%{"query" => "{ apiVersion }"}, [{"authorization", "Bearer garbage-token"}])

      assert context(conn).current_user == nil
    end

    test "a malformed authorization header yields an unauthenticated context" do
      conn = run(%{"query" => "{ apiVersion }"}, [{"authorization", "Basic dXNlcjpwdw=="}])

      assert context(conn).current_user == nil
    end

    test "an absent authorization header yields an unauthenticated context" do
      conn = run(%{"query" => "{ apiVersion }"})

      assert context(conn).current_user == nil
    end
  end

  describe "correlation IDs" do
    test "a valid UUID x-correlation-id header is honored" do
      id = Ecto.UUID.generate()

      conn = run(%{"query" => "{ apiVersion }"}, [{"x-correlation-id", id}])

      assert context(conn).correlation_id == id
    end

    test "a non-UUID header gets a fresh UUID instead" do
      conn = run(%{"query" => "{ apiVersion }"}, [{"x-correlation-id", "req-123"}])

      correlation_id = context(conn).correlation_id
      assert correlation_id != "req-123"
      assert {:ok, _} = Ecto.UUID.cast(correlation_id)
    end

    test "a missing header gets a generated UUID" do
      conn = run(%{"query" => "{ apiVersion }"})

      assert {:ok, _} = Ecto.UUID.cast(context(conn).correlation_id)
    end
  end

  describe "document size guard (SPEC §14.7)" do
    test "an oversized query is rejected with 413 and a stable code" do
      big_query = "{ apiVersion } #" <> String.duplicate("x", 65_536)

      conn = run(%{"query" => big_query})

      assert conn.halted
      assert conn.status == 413

      assert %{"errors" => [%{"extensions" => %{"code" => "DOCUMENT_TOO_LARGE"}}]} =
               Jason.decode!(conn.resp_body)
    end

    test "string-encoded variables count toward the byte budget" do
      conn =
        run(%{
          "query" => "{ apiVersion }",
          "variables" => Jason.encode!(%{"pad" => String.duplicate("x", 65_536)})
        })

      assert conn.status == 413
    end

    test "map variables count via their encoded size" do
      conn =
        run(%{
          "query" => "{ apiVersion }",
          "variables" => %{"pad" => String.duplicate("x", 65_536)}
        })

      assert conn.status == 413
    end

    test "a document within budget passes with small map variables" do
      conn = run(%{"query" => "{ apiVersion }", "variables" => %{"a" => 1}})

      refute conn.halted
      assert Map.has_key?(context(conn), :current_user)
    end

    test "a request without query or variables params is within budget" do
      # Non-binary query and non-binary/non-map variables both count as zero.
      conn = run(%{})

      refute conn.halted
    end
  end
end
