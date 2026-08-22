defmodule BillingCoreWeb.PageHTMLTest do
  use ExUnit.Case, async: true

  test "renders the home template directly" do
    html = Phoenix.Template.render_to_string(BillingCoreWeb.PageHTML, "home", "html", flash: %{})

    assert html =~ "Phoenix Framework"
    assert html =~ "https://phoenix.hexdocs.pm/overview.html"
  end

  test "compile-time template tracking is consistent" do
    # embed_templates/1 generates compile-tracking helpers attributed to the
    # module definition line; a false recompile check certifies the compiled
    # templates match the files on disk.
    refute BillingCoreWeb.PageHTML.__mix_recompile__?()

    # `use BillingCoreWeb, :html` makes the module a Phoenix.Component
    # container; it declares no function components of its own.
    assert BillingCoreWeb.PageHTML.__components__() == %{}
  end
end
