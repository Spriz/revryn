defmodule BillingCoreWeb.ErrorHTMLTest do
  # Note on coverage: render/2 (the only hand-written code) is fully covered
  # here. The module's line-coverage percentage stays below 100% because of
  # compiler/framework-generated metadata functions (__components__/0,
  # __info__/1, __phoenix_verify_routes__/1) that never run in tests.
  use BillingCoreWeb.ConnCase, async: true

  # Bring render_to_string/4 for testing custom views
  import Phoenix.Template, only: [render_to_string: 4]

  test "renders 404.html" do
    assert render_to_string(BillingCoreWeb.ErrorHTML, "404", "html", []) == "Not Found"
  end

  test "renders 500.html" do
    assert render_to_string(BillingCoreWeb.ErrorHTML, "500", "html", []) ==
             "Internal Server Error"
  end
end
