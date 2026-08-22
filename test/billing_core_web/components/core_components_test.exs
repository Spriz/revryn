defmodule BillingCoreWeb.CoreComponentsTest do
  @moduledoc """
  Direct render tests for the shared UI component branches the LiveView
  suites do not exercise: navigation buttons, textarea inputs, inline error
  rendering, the list component, stream-backed tables, and gettext error
  translation.
  """

  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias Phoenix.LiveView.LiveStream

  defp link_button(assigns) do
    ~H"""
    <BillingCoreWeb.CoreComponents.button navigate="/somewhere" variant="primary">
      Go there
    </BillingCoreWeb.CoreComponents.button>
    """
  end

  defp plain_button(assigns) do
    ~H"""
    <BillingCoreWeb.CoreComponents.button>Plain</BillingCoreWeb.CoreComponents.button>
    """
  end

  defp textarea_input(assigns) do
    ~H"""
    <BillingCoreWeb.CoreComponents.input
      type="textarea"
      id="notes-input"
      name="notes"
      value="hello world"
      label="Notes"
      errors={["is too short"]}
    />
    """
  end

  defp data_list(assigns) do
    ~H"""
    <BillingCoreWeb.CoreComponents.list>
      <:item title="Title">The post title</:item>
      <:item title="Views">42</:item>
    </BillingCoreWeb.CoreComponents.list>
    """
  end

  defp stream_table(assigns) do
    ~H"""
    <BillingCoreWeb.CoreComponents.table id="stream-table" rows={@rows}>
      <:col :let={{_id, item}} label="Name">{item.name}</:col>
    </BillingCoreWeb.CoreComponents.table>
    """
  end

  describe "button/1" do
    test "renders an anchor when navigation attributes are given" do
      html = render_component(&link_button/1, %{})

      assert html =~ ~s(href="/somewhere")
      assert html =~ "Go there"
      assert html =~ "btn-primary"
      refute html =~ "<button"
    end

    test "renders a plain button otherwise" do
      html = render_component(&plain_button/1, %{})

      assert html =~ "<button"
      assert html =~ "btn-soft"
    end
  end

  describe "input/1 textarea" do
    test "renders the textarea with its value, label, and inline errors" do
      html = render_component(&textarea_input/1, %{})

      assert html =~ "<textarea"
      assert html =~ ~s(id="notes-input")
      assert html =~ "hello world"
      assert html =~ "Notes"
      # A non-empty errors list switches to the error class and renders the
      # shared error paragraph (hero-exclamation-circle + message).
      assert html =~ "textarea-error"
      assert html =~ "hero-exclamation-circle"
      assert html =~ "is too short"
    end
  end

  describe "list/1" do
    test "renders one row per item with its title and body" do
      html = render_component(&data_list/1, %{})

      assert html =~ "Title"
      assert html =~ "The post title"
      assert html =~ "Views"
      assert html =~ "42"
      assert html =~ "list-row"
    end
  end

  describe "table/1 with LiveView streams" do
    test "derives dom ids from stream entries and marks the body phx-update=stream" do
      stream = LiveStream.new(:items, 0, [%{id: "row-a", name: "Ada"}], [])

      html = render_component(&stream_table/1, %{rows: stream})

      assert html =~ ~s(phx-update="stream")
      assert html =~ ~s(id="items-row-a")
      assert html =~ "Ada"
    end
  end

  describe "translate_error/1 and translate_errors/2" do
    test "translates a pluralized error through dngettext" do
      message =
        BillingCoreWeb.CoreComponents.translate_error(
          {"should be at least %{count} character(s)", [count: 3]}
        )

      assert message == "should be at least 3 character(s)"
    end

    test "translates a plain error through dgettext" do
      assert BillingCoreWeb.CoreComponents.translate_error({"can't be blank", []}) ==
               "can't be blank"
    end

    test "collects the translated errors for one field" do
      errors = [
        name: {"can't be blank", []},
        name: {"should be at least %{count} character(s)", [count: 3]},
        other: {"is invalid", []}
      ]

      assert BillingCoreWeb.CoreComponents.translate_errors(errors, :name) == [
               "can't be blank",
               "should be at least 3 character(s)"
             ]
    end
  end
end
