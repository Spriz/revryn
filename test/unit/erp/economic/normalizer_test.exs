defmodule BillingCore.ERP.Economic.NormalizerTest do
  use ExUnit.Case, async: true

  alias BillingCore.Domain.Money
  alias BillingCore.ERP.{Document, Fingerprint}
  alias BillingCore.ERP.Economic.Normalizer

  @booked_payload """
  {
    "bookedInvoiceNumber": 1077,
    "date": "2026-09-01",
    "currency": "DKK",
    "customer": {"customerNumber": 1001},
    "recipient": {
      "name": "Example   ApS",
      "address": "Hovedgaden 1",
      "zip": "8000",
      "city": "Aarhus",
      "country": "DK",
      "vatZone": {"vatZoneNumber": 1}
    },
    "paymentTerms": {"paymentTermsNumber": 14},
    "layout": {"layoutNumber": 21},
    "references": {"other": "abc:t1:intent-1:v1"},
    "vatAmount": 30000.00,
    "grossAmount": 150000.00,
    "pdf": {"download": "https://restapi.e-conomic.com/invoices/booked/1077/pdf"},
    "lines": [
      {
        "sortKey": 2,
        "lineNumber": 2,
        "product": {"productNumber": "SETUP"},
        "description": "Onboarding setup",
        "quantity": 1.0,
        "unitNetPrice": 0.29
      },
      {
        "sortKey": 1,
        "lineNumber": 1,
        "product": {"productNumber": "SAAS-ANNUAL"},
        "description": "Annual platform subscription — 2026-09-15 to 2027-09-14",
        "quantity": 1.0,
        "unitNetPrice": 120000.00,
        "accrual": {"startDate": "2026-09-15", "endDate": "2027-09-14"}
      }
    ]
  }
  """

  defp decode(raw), do: Jason.decode!(raw, floats: :decimals)

  defp booked_document, do: Normalizer.normalize(decode(@booked_payload), :booked)

  test "normalizes a booked payload with the exclusive accrual end restored" do
    document = booked_document()

    assert %Document{state: :booked} = document
    assert document.external_booked_number == "1077"
    assert document.external_reference == "abc:t1:intent-1:v1"
    assert document.customer_external_id == "1001"
    assert document.invoice_date == ~D[2026-09-01]
    assert document.currency == "DKK"
    assert document.payment_term_external_id == "14"
    assert document.layout_external_id == "21"

    # Lines are sorted by sortKey, 0-based order; provider inclusive endDate
    # converts back to the canonical exclusive end (SPEC §17.14, INV-007).
    assert [annual, setup] = document.lines
    assert annual.order == 0
    assert annual.product_external_id == "SAAS-ANNUAL"
    assert annual.recognition == {:over_time, ~D[2026-09-15], ~D[2027-09-15]}
    assert setup.order == 1
    assert setup.product_external_id == "SETUP"
    assert setup.recognition == :point_in_time
  end

  test "converts unitNetPrice to exact integer minor units without float drift" do
    document = booked_document()

    assert [annual, setup] = document.lines
    assert annual.amount == Money.new!("DKK", 12_000_000)
    assert setup.amount == Money.new!("DKK", 29)
  end

  test "large and small amounts convert exactly (quantity 1)" do
    payload =
      decode("""
      {
        "draftInvoiceNumber": 9,
        "date": "2026-01-01",
        "currency": "DKK",
        "references": {"other": "abc:t1:intent-2:v1"},
        "lines": [
          {"sortKey": 1, "product": {"productNumber": "A"}, "description": "a",
           "quantity": 1, "unitNetPrice": 1234567.89},
          {"sortKey": 2, "product": {"productNumber": "B"}, "description": "b",
           "quantity": 1, "unitNetPrice": 0.29}
        ]
      }
      """)

    assert %Document{lines: [big, small]} = Normalizer.normalize(payload, :draft)
    assert big.amount == Money.new!("DKK", 123_456_789)
    assert small.amount == Money.new!("DKK", 29)
  end

  test "recipient fingerprint tolerates provider whitespace normalization" do
    document = booked_document()

    expected =
      Fingerprint.recipient(%{
        legal_name: "Example ApS",
        address: "Hovedgaden 1",
        zip: "8000",
        city: "Aarhus",
        country: "DK",
        vat_zone_external_id: "1"
      })

    assert document.recipient_fingerprint == expected
  end

  test "description fingerprints match the canonical normalization" do
    document = booked_document()

    assert [annual, _setup] = document.lines

    assert annual.description_fingerprint ==
             Fingerprint.description("Annual platform subscription — 2026-09-15 to 2027-09-14")
  end

  test "provider-generated values land in provider_extras, not matching fields" do
    document = booked_document()

    assert document.provider_extras == %{
             vat_amount: Decimal.new("30000.00"),
             gross_amount: Decimal.new("150000.00"),
             booked_invoice_number: "1077",
             pdf_url: "https://restapi.e-conomic.com/invoices/booked/1077/pdf"
           }
  end

  test "external_hash is a stable sha256 that changes with matching-relevant content" do
    document = booked_document()

    assert document.external_hash =~ ~r/^[0-9a-f]{64}$/
    assert booked_document().external_hash == document.external_hash

    changed =
      @booked_payload
      |> String.replace(~s("unitNetPrice": 0.29), ~s("unitNetPrice": 0.30))
      |> decode()
      |> Normalizer.normalize(:booked)

    refute changed.external_hash == document.external_hash
  end

  test "string-typed monetary values parse exactly" do
    payload =
      decode("""
      {
        "draftInvoiceNumber": 9,
        "date": "2026-01-01",
        "currency": "DKK",
        "references": {"other": "abc:t1:intent-4:v1"},
        "lines": [
          {"sortKey": 1, "product": {"productNumber": "A"}, "description": "a",
           "quantity": 1, "unitNetPrice": "12.34"}
        ]
      }
      """)

    assert %Document{lines: [line]} = Normalizer.normalize(payload, :draft)
    assert line.amount == Money.new!("DKK", 1234)
  end

  test "Decimal-typed identifier numbers stringify canonically" do
    # floats: :decimals turns any JSON number with a fraction part into a
    # Decimal, including identifiers a provider emits as 421.0; those must
    # stringify without scientific notation or a trailing fraction.
    # (The stringify/1 catch-all for non-JSON value types is defensive and
    # unreachable through decoded provider payloads.)
    payload =
      decode("""
      {
        "draftInvoiceNumber": 421.0,
        "date": "2026-01-01",
        "currency": "DKK",
        "customer": {"customerNumber": 1001.0},
        "references": {"other": "abc:t1:intent-5:v1"},
        "lines": []
      }
      """)

    document = Normalizer.normalize(payload, :draft)
    assert document.external_draft_id == "421"
    assert document.customer_external_id == "1001"
  end

  test "rejects binary floats in payloads (INV-006)" do
    payload = %{
      "date" => "2026-01-01",
      "currency" => "DKK",
      "references" => %{"other" => "abc:t1:intent-3:v1"},
      "lines" => [
        %{
          "sortKey" => 1,
          "product" => %{"productNumber" => "A"},
          "description" => "a",
          "quantity" => 1,
          "unitNetPrice" => 0.29
        }
      ]
    }

    assert_raise ArgumentError, ~r/floats are prohibited/, fn ->
      Normalizer.normalize(payload, :draft)
    end
  end
end
