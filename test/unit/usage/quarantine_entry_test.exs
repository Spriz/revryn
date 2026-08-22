defmodule BillingCore.Usage.QuarantineEntryTest do
  use ExUnit.Case, async: true

  alias BillingCore.Usage.QuarantineEntry

  test "reasons/0 mirrors the database check constraint" do
    assert QuarantineEntry.reasons() ==
             ~w(too_old too_far_future unknown_subscription unknown_metric oversized_properties)
  end

  test "every reason is a plain string, ready for the text column" do
    assert Enum.all?(QuarantineEntry.reasons(), &is_binary/1)
  end

  test "new entries keep the canonical payload and start unresolved" do
    entry = %QuarantineEntry{}
    assert entry.payload == %{}
    assert is_nil(entry.resolved_at)
  end
end
