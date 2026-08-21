defmodule BillingCoreWeb.PageController do
  use BillingCoreWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
