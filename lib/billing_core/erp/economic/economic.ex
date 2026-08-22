defmodule BillingCore.ERP.Economic do
  @moduledoc """
  e-conomic ERP adapter (SPEC §17) implementing `BillingCore.ERP.Adapter`.

  The adapter translates representation only (SPEC §16.2): it never
  recalculates price, discount, proration, or recognition policy. All HTTP
  traffic goes through `BillingCore.ERP.Economic.Client`; all provider reads
  are normalized by `BillingCore.ERP.Economic.Normalizer` before they cross
  the port boundary.

  ## Money at this boundary

  The provider requires monetary values as JSON numbers. `unitNetPrice` is
  produced from integer minor units by exact `Decimal` division at the
  currency scale and emitted as a bare decimal number literal (via
  `Jason.Fragment`) — binary floating point is never involved on either the
  write or the read path (responses decode with `floats: :decimals`). This
  JSON-number encoding of money is acceptable at this provider boundary only
  (INV-006 holds everywhere above the adapter).

  ## Outcome semantics

  Transport failures on writes (create/update/book) return
  `{:unknown, recovery_hint}` — the request may have reached the provider —
  and the caller must reconcile via `find_document/2` before any retry
  (SPEC §17.7, INV-008/009). Transport failures on reads return
  `{:error, {:provider_failure, reason}}`. HTTP error statuses classify per
  SPEC §17.13.
  """

  @behaviour BillingCore.ERP.Adapter

  alias BillingCore.Domain.{Money, Period}
  alias BillingCore.ERP.{CanonicalInvoice, Document}
  alias BillingCore.ERP.CanonicalInvoice.Line
  alias BillingCore.ERP.Economic.{Client, Normalizer}
  alias BillingCore.ERP.Vouchers.{AttachmentEvidence, FinanceVoucher, FinanceVoucherLine, Voucher}

  @capabilities %{
    supports_draft_invoices: true,
    supports_draft_updates: true,
    supports_booking: true,
    supports_invoice_webhooks: true,
    supports_line_accrual_periods: true,
    supports_customer_provisioning: true,
    supports_customer_credit_settlements: false,
    supports_finance_vouchers: true,
    supports_voucher_attachments: true,
    supported_delivery_modes: [:none, :email, :einvoice],
    amount_scale: 2,
    quantity_scale: 2
  }

  # -- capabilities -----------------------------------------------------------

  @impl true
  def capabilities(_context), do: {:ok, @capabilities}

  # -- preflight (SPEC §17.3) -------------------------------------------------

  @impl true
  def preflight(context, preflight_input) do
    input = preflight_input || %{}

    with {:ok, self_checks, evidence} <- self_checks(context),
         {:ok, mapping_checks} <- mapping_checks(context),
         {:ok, product_checks} <-
           resource_checks(context, :product, "/products", Map.get(input, :product_external_ids)),
         {:ok, customer_checks} <-
           resource_checks(
             context,
             :customer,
             "/customers",
             Map.get(input, :customer_external_ids)
           ),
         {:ok, period_checks, period_evidence} <-
           accounting_period_checks(context, Map.get(input, :required_dates)) do
      {:ok,
       %{
         checks:
           self_checks ++ mapping_checks ++ product_checks ++ customer_checks ++ period_checks,
         capabilities: @capabilities,
         evidence: Map.merge(evidence, period_evidence)
       }}
    end
  end

  defp self_checks(context) do
    case Client.get(context, "/self") do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        agreement = %{
          check: :agreement,
          status: :pass,
          detail:
            "agreement #{stringify(body["agreementNumber"]) || "unknown"}, " <>
              "base currency #{base_currency(body) || "unknown"}"
        }

        evidence = %{
          agreement_number: stringify(body["agreementNumber"]),
          base_currency: base_currency(body),
          modules: module_names(body)
        }

        {:ok, [agreement, modules_check(body), roles_check(body)], evidence}

      {:ok, response} ->
        with :ok <- reject_auth_failure(response) do
          {:ok, [failed_check(:agreement, response)], %{}}
        end

      {:error, {:transport, reason}} ->
        {:ok, [transport_failed_check(:agreement, reason)], %{}}
    end
  end

  defp base_currency(body) do
    body["baseCurrency"] || get_in(body, ["settings", "baseCurrency"])
  end

  defp module_names(body) do
    case body["modules"] do
      modules when is_list(modules) ->
        Enum.flat_map(modules, fn
          %{"name" => name} when is_binary(name) -> [name]
          name when is_binary(name) -> [name]
          _other -> []
        end)

      _absent ->
        nil
    end
  end

  defp modules_check(body) do
    case module_names(body) do
      nil ->
        %{
          check: :modules,
          status: :warn,
          detail: "/self did not report modules; verify Accruals availability manually"
        }

      names ->
        if Enum.any?(names, &String.contains?(String.downcase(&1), "accrual")) do
          %{check: :modules, status: :pass, detail: "modules: " <> Enum.join(names, ", ")}
        else
          %{
            check: :modules,
            status: :warn,
            detail:
              "Accruals module not reported; over-time lines may fail. " <>
                "Modules: " <> Enum.join(names, ", ")
          }
        end
    end
  end

  defp roles_check(body) do
    case get_in(body, ["application", "requiredRoles"]) do
      roles when is_list(roles) ->
        names =
          Enum.map(roles, fn
            %{"name" => name} when is_binary(name) -> name
            role when is_binary(role) -> role
            other -> stringify(other)
          end)

        %{check: :roles, status: :pass, detail: "application roles: " <> Enum.join(names, ", ")}

      _absent ->
        %{
          check: :roles,
          status: :warn,
          detail: "/self did not report application roles; verify Sales/Bookkeeping access"
        }
    end
  end

  defp mapping_checks(context) do
    mappings = Map.get(context, :mappings) || %{}

    checks = [
      {:layout, "/layouts", Map.get(mappings, :layout_external_id)},
      {:payment_terms, "/payment-terms", Map.get(mappings, :payment_term_external_id)}
    ]

    Enum.reduce_while(checks, {:ok, []}, fn
      {_check, _path, nil}, {:ok, acc} ->
        {:cont, {:ok, acc}}

      {check, path, id}, {:ok, acc} ->
        case existence_check(context, check, path, id) do
          {:ok, result} -> {:cont, {:ok, acc ++ [result]}}
          {:error, _reason} = error -> {:halt, error}
        end
    end)
  end

  defp resource_checks(_context, _check, _path, nil), do: {:ok, []}
  defp resource_checks(_context, _check, _path, []), do: {:ok, []}

  defp resource_checks(context, check, path, ids) when is_list(ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case existence_check(context, check, path, id) do
        {:ok, result} -> {:cont, {:ok, acc ++ [result]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp existence_check(context, check, path, id) do
    case Client.get(context, "#{path}/#{id}") do
      {:ok, %{status: status}} when status in 200..299 ->
        {:ok, %{check: check, status: :pass, detail: "#{check} #{id} exists"}}

      {:ok, %{status: 404}} ->
        {:ok, %{check: check, status: :fail, detail: "#{check} #{id} not found (404)"}}

      {:ok, response} ->
        with :ok <- reject_auth_failure(response) do
          {:ok,
           %{
             check: check,
             status: :fail,
             detail: "#{check} #{id} lookup failed with status #{response.status}"
           }}
        end

      {:error, {:transport, reason}} ->
        {:ok, %{check: check, status: :fail, detail: "#{check} #{id} lookup failed: #{reason}"}}
    end
  end

  defp accounting_period_checks(context, required_dates) do
    dates = required_dates || []

    case Client.get(context, "/accounting-years") do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        years = normalize_accounting_years(body)
        evidence = %{accounting_years: years}

        checks =
          case dates do
            [] ->
              [
                %{
                  check: :accounting_periods,
                  status: :pass,
                  detail: "#{length(years)} accounting year(s) visible"
                }
              ]

            dates ->
              Enum.map(dates, &date_period_check(&1, years))
          end

        {:ok, checks, evidence}

      {:ok, response} ->
        with :ok <- reject_auth_failure(response) do
          {:ok, [failed_check(:accounting_periods, response)], %{}}
        end

      {:error, {:transport, reason}} ->
        {:ok, [transport_failed_check(:accounting_periods, reason)], %{}}
    end
  end

  defp normalize_accounting_years(body) do
    for year <- List.wrap(body["collection"]),
        is_map(year),
        from = parse_date(year["fromDate"]),
        to = parse_date(year["toDate"]) do
      %{
        year: stringify(year["year"]),
        from_date: from,
        to_date: to,
        closed: Map.get(year, "closed", :unknown)
      }
    end
  end

  defp date_period_check(%Date{} = date, years) do
    covering =
      Enum.find(years, fn year ->
        not Date.before?(date, year.from_date) and not Date.after?(date, year.to_date)
      end)

    case covering do
      nil ->
        %{
          check: :accounting_periods,
          status: :fail,
          detail: "#{date} falls in no visible accounting year"
        }

      %{closed: true} = year ->
        %{
          check: :accounting_periods,
          status: :fail,
          detail: "#{date} falls in closed accounting year #{year.year}"
        }

      %{closed: false} = year ->
        %{
          check: :accounting_periods,
          status: :pass,
          detail: "#{date} falls in open accounting year #{year.year}"
        }

      year ->
        %{
          check: :accounting_periods,
          status: :warn,
          detail:
            "#{date} falls in accounting year #{year.year}; " <>
              "provider did not report open/closed state"
        }
    end
  end

  defp failed_check(check, %{status: status}) do
    %{check: check, status: :fail, detail: "#{check} check failed with status #{status}"}
  end

  defp transport_failed_check(check, reason) do
    %{check: check, status: :fail, detail: "#{check} check failed: #{reason}"}
  end

  # Auth failures abort the whole preflight (SPEC §17.2, §17.13).
  defp reject_auth_failure(%{status: 401} = response),
    do: {:error, classify(response)}

  defp reject_auth_failure(%{status: 403} = response),
    do: {:error, classify(response)}

  defp reject_auth_failure(_response), do: :ok

  # -- create draft (SPEC §17.8) ----------------------------------------------

  @impl true
  def create_draft(context, %CanonicalInvoice{} = invoice, operation_key) do
    with {:ok, invoice} <- ensure_document_defaults(context, invoice) do
      do_create_draft(context, invoice, operation_key)
    end
  end

  defp do_create_draft(context, %CanonicalInvoice{} = invoice, operation_key) do
    body = draft_body(invoice)

    case Client.post(context, "/invoices/drafts", body, operation_key) do
      {:ok, %{status: status, body: response_body}} when status in 200..299 ->
        finalize_draft_write(context, invoice, response_body)

      {:ok, response} ->
        {:error, classify(response)}

      {:error, {:transport, reason}} ->
        {:unknown, write_lost_hint(reason, [{:external_reference, invoice.external_reference}])}
    end
  end

  # -- update draft (SPEC §17.9) ----------------------------------------------

  @impl true
  def update_draft(context, document_ref, invoice, operation_key)

  def update_draft(context, {:draft, draft_id}, %CanonicalInvoice{} = invoice, operation_key) do
    invoice =
      case ensure_document_defaults(context, invoice) do
        {:ok, resolved} -> resolved
        {:error, _reason} -> invoice
      end

    body =
      invoice
      |> draft_body()
      |> Map.put("draftInvoiceNumber", numberish(draft_id))

    case Client.put(context, "/invoices/drafts/#{draft_id}", body, operation_key) do
      {:ok, %{status: status, body: response_body}} when status in 200..299 ->
        finalize_draft_write(context, invoice, response_body, draft_id)

      {:ok, response} ->
        {:error, classify(response)}

      {:error, {:transport, reason}} ->
        {:unknown,
         write_lost_hint(reason, [
           {:draft, draft_id},
           {:external_reference, invoice.external_reference}
         ])}
    end
  end

  def update_draft(_context, {:booked, number}, _invoice, _operation_key) do
    {:error, {:conflict, "booked invoice #{number} is immutable; issue a compensating document"}}
  end

  def update_draft(context, {:external_reference, reference}, invoice, operation_key) do
    case find_document(context, reference) do
      {:ok, %Document{state: :draft, external_draft_id: draft_id}} when is_binary(draft_id) ->
        update_draft(context, {:draft, draft_id}, invoice, operation_key)

      {:ok, %Document{state: :booked, external_booked_number: number}} ->
        update_draft(context, {:booked, number}, invoice, operation_key)

      {:ok, nil} ->
        {:error, {:not_found, "no draft or booked invoice with reference #{reference}"}}

      {:error, _reason} = error ->
        error
    end
  end

  # -- reads ------------------------------------------------------------------

  @impl true
  def get_document(context, {:draft, draft_id}) do
    fetch_document(context, "/invoices/drafts/#{draft_id}", :draft)
  end

  def get_document(context, {:booked, number}) do
    fetch_document(context, "/invoices/booked/#{number}", :booked)
  end

  def get_document(context, {:external_reference, reference}) do
    case find_document(context, reference) do
      {:ok, nil} ->
        {:error, {:not_found, "no draft or booked invoice with reference #{reference}"}}

      {:ok, %Document{} = document} ->
        {:ok, document}

      {:error, _reason} = error ->
        error
    end
  end

  @impl true
  def find_document(context, external_reference) do
    filter = "references.other$eq:#{external_reference}"

    with {:ok, draft_hit} <- search_collection(context, "/invoices/drafts", filter),
         {:ok, booked_hit} <- search_collection(context, "/invoices/booked", filter) do
      cond do
        booked_hit != nil -> resolve_hit(context, booked_hit, :booked)
        draft_hit != nil -> resolve_hit(context, draft_hit, :draft)
        true -> {:ok, nil}
      end
    end
  end

  defp search_collection(context, url, filter) do
    case Client.get(context, url, params: [filter: filter]) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body |> Map.get("collection", []) |> List.first()}

      {:ok, response} ->
        {:error, classify(response)}

      {:error, {:transport, reason}} ->
        {:error, {:provider_failure, reason}}
    end
  end

  # Collection results usually omit lines; fetch the full document unless the
  # hit is already complete.
  defp resolve_hit(context, hit, state) do
    cond do
      complete_payload?(hit) ->
        {:ok, Normalizer.normalize(hit, state)}

      state == :booked and hit["bookedInvoiceNumber"] != nil ->
        fetch_document(context, "/invoices/booked/#{hit["bookedInvoiceNumber"]}", :booked)

      state == :draft and hit["draftInvoiceNumber"] != nil ->
        fetch_document(context, "/invoices/drafts/#{hit["draftInvoiceNumber"]}", :draft)

      true ->
        {:error, {:provider_failure, "search hit lacked an invoice number"}}
    end
  end

  defp fetch_document(context, url, state) do
    case Client.get(context, url) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, Normalizer.normalize(body, state)}

      {:ok, response} ->
        {:error, classify(response)}

      {:error, {:transport, reason}} ->
        {:error, {:provider_failure, reason}}
    end
  end

  # -- booking (SPEC §17.10) --------------------------------------------------

  @impl true
  def book_document(context, document_ref, booking_options, operation_key)

  def book_document(context, {:draft, draft_id}, booking_options, operation_key) do
    delivery_mode = Map.get(booking_options, :delivery_mode, :none)

    body =
      %{"draftInvoice" => %{"draftInvoiceNumber" => numberish(draft_id)}}
      |> put_send_by(delivery_mode)

    search_refs = booking_search_refs(draft_id, booking_options)

    case Client.post(context, "/invoices/booked", body, operation_key) do
      {:ok, %{status: status, body: response_body}} when status in 200..299 ->
        case stringify(response_body["bookedInvoiceNumber"]) do
          nil ->
            {:unknown,
             %{
               search_by: search_refs,
               detail: "booking response lacked bookedInvoiceNumber; reconcile before retry"
             }}

          booked_number ->
            case fetch_document(context, "/invoices/booked/#{booked_number}", :booked) do
              {:ok, document} ->
                {:ok, document}

              {:error, _reason} ->
                {:unknown,
                 %{
                   search_by: [{:booked, booked_number} | search_refs],
                   detail:
                     "booked as #{booked_number} but read-back failed; reconcile before retry"
                 }}
            end
        end

      {:ok, response} ->
        {:error, classify(response)}

      {:error, {:transport, reason}} ->
        {:unknown, write_lost_hint(reason, search_refs)}
    end
  end

  def book_document(_context, {:booked, number}, _booking_options, _operation_key) do
    {:error, {:conflict, "invoice #{number} is already booked"}}
  end

  def book_document(context, {:external_reference, reference}, booking_options, operation_key) do
    case find_document(context, reference) do
      {:ok, %Document{state: :draft, external_draft_id: draft_id}} when is_binary(draft_id) ->
        options = Map.put_new(booking_options, :external_reference, reference)
        book_document(context, {:draft, draft_id}, options, operation_key)

      {:ok, %Document{state: :booked, external_booked_number: number}} ->
        {:error, {:conflict, "invoice #{reference} is already booked as #{number}"}}

      {:ok, nil} ->
        {:error, {:not_found, "no draft invoice with reference #{reference}"}}

      {:error, _reason} = error ->
        error
    end
  end

  defp put_send_by(body, :none), do: body
  defp put_send_by(body, :email), do: Map.put(body, "sendBy", "email")
  defp put_send_by(body, :einvoice), do: Map.put(body, "sendBy", "ean")

  defp booking_search_refs(draft_id, booking_options) do
    case Map.get(booking_options, :external_reference) do
      nil -> [{:draft, stringify(draft_id)}]
      reference -> [{:draft, stringify(draft_id)}, {:external_reference, reference}]
    end
  end

  # -- finance vouchers (SPEC §17.16) ----------------------------------------

  @impl true
  def create_finance_voucher(context, %FinanceVoucher{} = voucher, operation_key) do
    with :ok <- FinanceVoucher.validate(voucher) do
      journal = voucher.journal_external_id
      body = finance_voucher_body(voucher)

      case Client.post(context, "/journals/#{journal}/vouchers", body, operation_key) do
        {:ok, %{status: status, body: response_body}} when status in 200..299 ->
          case normalize_finance_voucher(response_body, voucher) do
            {:ok, normalized} ->
              {:ok, normalized}

            :unknown ->
              {:unknown,
               %{
                 search_by: [{:external_reference, voucher.external_reference}],
                 detail:
                   "voucher accepted but response lacked a voucher number; reconcile before retry"
               }}
          end

        {:ok, response} ->
          {:error, classify(response)}

        {:error, {:transport, reason}} ->
          {:unknown, write_lost_hint(reason, [{:external_reference, voucher.external_reference}])}
      end
    end
  end

  @impl true
  def find_finance_voucher(context, external_reference) when is_binary(external_reference) do
    journal = finance_journal(context)

    case Client.get(context, "/journals/#{journal}/vouchers",
           params: [filter: "text$eq:#{external_reference}"]
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        case body |> Map.get("collection", []) |> List.first() do
          nil ->
            {:ok, nil}

          payload ->
            case normalize_finance_voucher(
                   payload,
                   finance_voucher_defaults(context, external_reference)
                 ) do
              {:ok, voucher} ->
                {:ok, voucher}

              :unknown ->
                {:error, {:provider_failure, "voucher search hit lacked required fields"}}
            end
        end

      {:ok, response} ->
        {:error, classify(response)}

      {:error, {:transport, reason}} ->
        {:error, {:provider_failure, reason}}
    end
  end

  @impl true
  def get_finance_voucher(context, {:voucher, voucher_number}) do
    journal = finance_journal(context)
    year = finance_accounting_year(context)

    fetch_finance_voucher(context, journal, year, voucher_number)
  end

  def get_finance_voucher(context, {:external_reference, external_reference}) do
    find_finance_voucher(context, external_reference)
  end

  @impl true
  def attach_voucher_report(context, voucher_ref, %AttachmentEvidence{} = evidence, operation_key) do
    with :ok <- AttachmentEvidence.validate(evidence, require_content: true),
         {:ok, %Voucher{} = voucher} <- resolve_finance_voucher(context, voucher_ref) do
      path = attachment_file_path(voucher)

      case Client.post_multipart(
             context,
             path,
             [
               file:
                 {evidence.content,
                  filename: evidence.filename, content_type: evidence.content_type}
             ],
             operation_key
           ) do
        {:ok, %{status: status}} when status in 200..299 ->
          :ok

        {:ok, response} ->
          {:error, classify(response)}

        {:error, {:transport, reason}} ->
          {:unknown,
           write_lost_hint(reason, [
             {:voucher, voucher.external_voucher_number},
             {:external_reference, voucher.external_reference}
           ])}
      end
    end
  end

  @impl true
  def get_voucher_attachment(context, voucher_ref) do
    with {:ok, %Voucher{} = voucher} <- resolve_finance_voucher(context, voucher_ref) do
      case Client.get(context, attachment_metadata_path(voucher)) do
        {:ok, %{status: 404}} ->
          {:ok, nil}

        {:ok, %{status: status, body: body}} when status in 200..299 ->
          fetch_attachment_evidence(context, voucher, body)

        {:ok, response} ->
          {:error, classify(response)}

        {:error, {:transport, reason}} ->
          {:error, {:provider_failure, reason}}
      end
    end
  end

  defp resolve_finance_voucher(context, {:voucher, _number} = ref),
    do: require_finance_voucher(get_finance_voucher(context, ref), ref)

  defp resolve_finance_voucher(context, {:external_reference, _reference} = ref),
    do: require_finance_voucher(get_finance_voucher(context, ref), ref)

  defp require_finance_voucher({:ok, nil}, ref), do: {:error, {:not_found, ref}}
  defp require_finance_voucher(result, _ref), do: result

  defp fetch_finance_voucher(context, journal, year, number) do
    case Client.get(context, "/journals/#{journal}/vouchers/#{year}-#{number}") do
      {:ok, %{status: 404}} ->
        {:ok, nil}

      {:ok, %{status: status, body: body}} when status in 200..299 ->
        case normalize_finance_voucher(body, finance_voucher_defaults(context, nil)) do
          {:ok, voucher} -> {:ok, voucher}
          :unknown -> {:error, {:provider_failure, "voucher read lacked required fields"}}
        end

      {:ok, response} ->
        {:error, classify(response)}

      {:error, {:transport, reason}} ->
        {:error, {:provider_failure, reason}}
    end
  end

  defp finance_voucher_body(%FinanceVoucher{} = voucher) do
    %{
      "accountingYear" => %{"year" => numberish(voucher.accounting_year_external_id)},
      "entries" => %{
        "financeVouchers" => Enum.map(voucher.lines, &finance_voucher_line_body(&1, voucher))
      }
    }
  end

  defp finance_voucher_line_body(%FinanceVoucherLine{} = line, voucher) do
    %{
      "account" => %{"accountNumber" => numberish(line.account_external_id)},
      "amount" => voucher_amount(line.amount),
      "date" => Date.to_iso8601(voucher.accounting_date),
      "text" => voucher_entry_text(voucher.external_reference, line),
      "currency" => %{"code" => voucher.currency}
    }
  end

  defp voucher_amount(%Money{} = money) do
    money
    |> Money.to_major_decimal()
    |> Decimal.round(Money.exponent(money.currency))
    |> Decimal.to_string(:normal)
    |> Jason.Fragment.new()
  end

  defp finance_journal(context) do
    Map.get(context, :journal_external_id) ||
      get_in(context, [:mappings, :credit_close_journal_external_id])
  end

  defp finance_accounting_year(context) do
    Map.get(context, :accounting_year_external_id) ||
      get_in(context, [:mappings, :credit_close_accounting_year_external_id])
  end

  defp finance_voucher_defaults(context, reference) do
    currency = Map.get(context, :currency, "DKK")

    liability_account =
      Map.get(context, :credit_liability_account_external_id) ||
        get_in(context, [:mappings, :credit_liability_account_external_id])

    expected_lines =
      if is_binary(liability_account) and liability_account != "" do
        [
          %FinanceVoucherLine{
            line_key: "customer-credit-liability",
            account_external_id: liability_account,
            amount: Money.zero(currency),
            role: :customer_credit_liability
          }
        ]
      else
        []
      end

    %FinanceVoucher{
      external_reference: reference || "unknown",
      accounting_date: Map.get(context, :accounting_date, Date.utc_today()),
      accounting_year_external_id: stringify(finance_accounting_year(context) || "unknown"),
      journal_external_id: stringify(finance_journal(context) || "unknown"),
      currency: currency,
      lines: expected_lines
    }
  end

  defp normalize_finance_voucher(body, %FinanceVoucher{} = defaults) when is_map(body) do
    number = stringify(body["voucherNumber"] || body["number"])

    if is_nil(number) do
      :unknown
    else
      entries = get_in(body, ["entries", "financeVouchers"]) || body["financeVouchers"] || []

      with {:ok, date} <- voucher_date(body, defaults.accounting_date),
           {:ok, lines} <- normalize_voucher_lines(entries, defaults) do
        voucher = %Voucher{
          external_voucher_number: number,
          external_reference: voucher_reference(body, defaults.external_reference),
          accounting_date: date,
          accounting_year_external_id:
            stringify(
              get_in(body, ["accountingYear", "year"]) || defaults.accounting_year_external_id
            ),
          journal_external_id:
            stringify(get_in(body, ["journal", "journalNumber"]) || defaults.journal_external_id),
          currency: currency_code(body["currency"]) || defaults.currency,
          lines: lines,
          provider_extras: %{}
        }

        {:ok, %{voucher | external_hash: BillingCore.Domain.Canonical.hash(voucher)}}
      else
        _error -> :unknown
      end
    end
  end

  defp normalize_voucher_lines(lines, %FinanceVoucher{} = defaults) when is_list(lines) do
    lines
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {line, index}, {:ok, acc} ->
      account = get_in(line, ["account", "accountNumber"]) || line["accountNumber"]
      amount = line["amount"]

      with account when not is_nil(account) <- account,
           {:ok, money} <- voucher_money(amount, defaults.currency) do
        normalized = %FinanceVoucherLine{
          line_key: stringify(line["lineNumber"] || index + 1),
          account_external_id: stringify(account),
          amount: money,
          role: expected_line_role(defaults.lines, stringify(account)),
          description: line["text"]
        }

        {:cont, {:ok, acc ++ [normalized]}}
      else
        _error -> {:halt, :error}
      end
    end)
  end

  defp normalize_voucher_lines(_lines, _defaults), do: :error

  defp voucher_money(%Decimal{} = amount, currency) do
    multiplier = Decimal.new(Integer.pow(10, Money.exponent(currency)))
    minor = Decimal.mult(amount, multiplier)

    if Decimal.equal?(minor, Decimal.round(minor, 0)) do
      {:ok, Money.new!(currency, Decimal.to_integer(minor))}
    else
      :error
    end
  end

  defp voucher_money(amount, currency) when is_integer(amount),
    do: voucher_money(Decimal.new(amount), currency)

  defp voucher_money(amount, currency) when is_binary(amount),
    do: voucher_money(Decimal.new(amount), currency)

  defp voucher_money(_amount, _currency), do: :error

  defp voucher_date(body, fallback) do
    case parse_date(body["date"]) || fallback do
      %Date{} = date -> {:ok, date}
      _other -> :error
    end
  end

  defp voucher_reference(body, fallback) do
    body["text"] || get_in(body, ["entries", "financeVouchers", Access.at(0), "text"]) || fallback
  end

  defp expected_line_role(lines, account_external_id) do
    case Enum.find(lines, &(&1.account_external_id == account_external_id)) do
      %FinanceVoucherLine{role: role} -> role
      nil -> :balancing
    end
  end

  # The sole liability line carries the exact stable reference so provider
  # equality filters can recover an unknown write. Aggregate balancing lines
  # may add human context, but keep the same reference prefix.
  defp voucher_entry_text(reference, %FinanceVoucherLine{
         role: :customer_credit_liability
       }),
       do: reference

  defp voucher_entry_text(reference, %FinanceVoucherLine{description: nil}), do: reference

  defp voucher_entry_text(reference, %FinanceVoucherLine{description: description}) do
    # e-conomic caps entry text. The recovery reference is always first and is
    # never truncated by an optional aggregate description.
    String.slice(reference <> " | " <> description, 0, 250)
  end

  defp currency_code(%{"code" => code}) when is_binary(code), do: code
  defp currency_code(code) when is_binary(code), do: code
  defp currency_code(_other), do: nil

  defp attachment_metadata_path(%Voucher{} = voucher) do
    "/journals/#{voucher.journal_external_id}/vouchers/#{voucher.accounting_year_external_id}-#{voucher.external_voucher_number}/attachment"
  end

  defp attachment_file_path(%Voucher{} = voucher),
    do: attachment_metadata_path(voucher) <> "/file"

  defp fetch_attachment_evidence(context, voucher, metadata) do
    case Client.get(context, attachment_file_path(voucher)) do
      {:ok, %{status: status, body: content, headers: headers}}
      when status in 200..299 and is_binary(content) ->
        {:ok, normalize_attachment(metadata, content, headers)}

      {:ok, response} ->
        {:error, classify(response)}

      {:error, {:transport, reason}} ->
        {:error, {:provider_failure, reason}}
    end
  end

  defp normalize_attachment(body, content, headers) when is_map(body) and is_binary(content) do
    %AttachmentEvidence{
      filename: body["fileName"] || body["name"] || "voucher-report.pdf",
      content_type: attachment_content_type(headers),
      sha256: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower),
      byte_size: byte_size(content),
      external_attachment_id: stringify(body["attachmentNumber"] || body["id"])
    }
  end

  defp attachment_content_type(headers) do
    headers
    |> Map.get("content-type", [])
    |> List.first()
    |> case do
      value when is_binary(value) -> value
      _other -> "application/pdf"
    end
  end

  # -- document defaults (SPEC §17.4) -----------------------------------------

  # e-conomic requires layout, paymentTerms, and recipient.vatZone on every
  # draft and does NOT default them from the customer server-side. When the
  # canonical invoice does not carry them (team settings unset, recipient
  # snapshot without a VAT zone), resolve them from the mapped customer —
  # its e-conomic record always has all three configured. Explicit values
  # always win over the customer's defaults.
  defp ensure_document_defaults(context, %CanonicalInvoice{} = invoice) do
    if invoice.payment_term_external_id && invoice.layout_external_id &&
         Map.get(invoice.recipient, :vat_zone_external_id) do
      {:ok, invoice}
    else
      with {:ok, defaults} <- customer_defaults(context, invoice.customer_external_id),
           {:ok, payment_term} <-
             fallback_number(
               context,
               invoice.payment_term_external_id || defaults.payment_term,
               "/payment-terms",
               "paymentTermsNumber"
             ),
           {:ok, layout} <-
             fallback_number(
               context,
               invoice.layout_external_id || defaults.layout,
               "/layouts",
               "layoutNumber"
             ) do
        recipient =
          case Map.get(invoice.recipient, :vat_zone_external_id) do
            nil -> Map.put(invoice.recipient, :vat_zone_external_id, defaults.vat_zone)
            _present -> invoice.recipient
          end

        {:ok,
         %{
           invoice
           | recipient: recipient,
             payment_term_external_id: payment_term,
             layout_external_id: layout
         }}
      end
    end
  end

  # Last rung: the agreement's first layout / payment term. Safe because
  # drafts are human-reviewed before booking (ADR-009 draft-first); the
  # VAT zone deliberately has NO such fallback — guessing it would mean
  # wrong VAT, so it must come from the customer or the recipient snapshot.
  defp fallback_number(_context, value, _url, _field) when is_binary(value), do: {:ok, value}

  defp fallback_number(context, nil, url, field) do
    case Client.get(context, url, params: [pagesize: 1]) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        first = body |> Map.get("collection", []) |> List.first() || %{}
        {:ok, stringify(first[field])}

      {:ok, response} ->
        {:error, classify(response)}

      {:error, {:transport, reason}} ->
        {:error, {:provider_failure, reason}}
    end
  end

  defp customer_defaults(context, customer_number) do
    case Client.get(context, "/customers/#{customer_number}") do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_map(body) ->
        {:ok,
         %{
           payment_term: stringify(get_in(body, ["paymentTerms", "paymentTermsNumber"])),
           layout: stringify(get_in(body, ["layout", "layoutNumber"])),
           vat_zone: stringify(get_in(body, ["vatZone", "vatZoneNumber"]))
         }}

      {:ok, response} ->
        {:error, classify(response)}

      {:error, {:transport, reason}} ->
        {:error, {:provider_failure, reason}}
    end
  end

  # -- write body mapping (SPEC §17.4, §17.5) ---------------------------------

  defp draft_body(%CanonicalInvoice{} = invoice) do
    # Credit notes carry positive canonical magnitudes; the adapter renders
    # them as negative amounts (SPEC §17.4 "document type").
    sign = if invoice.document_type == :credit_note, do: -1, else: 1

    %{
      "date" => Date.to_iso8601(invoice.invoice_date),
      "currency" => invoice.currency,
      "customer" => %{"customerNumber" => numberish(invoice.customer_external_id)},
      "recipient" => recipient_body(invoice.recipient),
      "references" => %{"other" => invoice.external_reference},
      "lines" => Enum.map(invoice.lines, &line_body(&1, sign))
    }
    |> put_number_reference(
      "paymentTerms",
      "paymentTermsNumber",
      invoice.payment_term_external_id
    )
    |> put_number_reference("layout", "layoutNumber", invoice.layout_external_id)
  end

  defp recipient_body(recipient) do
    %{"name" => Map.fetch!(recipient, :legal_name)}
    |> put_present("address", Map.get(recipient, :address))
    |> put_present("zip", Map.get(recipient, :zip))
    |> put_present("city", Map.get(recipient, :city))
    |> put_present("country", Map.get(recipient, :country))
    |> put_vat_zone(Map.get(recipient, :vat_zone_external_id))
  end

  defp put_vat_zone(body, nil), do: body

  defp put_vat_zone(body, vat_zone_id) do
    Map.put(body, "vatZone", %{"vatZoneNumber" => numberish(vat_zone_id)})
  end

  defp line_body(%Line{} = line, sign) do
    amount = if sign == -1, do: Money.negate(line.amount), else: line.amount

    base = %{
      "sortKey" => line.order + 1,
      "product" => %{"productNumber" => line.product_external_id},
      "description" => line.description,
      "quantity" => 1,
      "unitNetPrice" => unit_net_price(amount)
    }

    case line.recognition do
      :point_in_time ->
        base

      {:over_time, %Period{} = period} ->
        Map.put(base, "accrual", %{
          "startDate" => Date.to_iso8601(period.start_date),
          "endDate" => Date.to_iso8601(Period.inclusive_end(period))
        })
    end
  end

  # Exact major-unit amount at the currency scale, emitted as a bare JSON
  # number because the provider requires numbers for money. The digits come
  # from exact integer-minor-unit division rendered in plain decimal
  # notation via `Jason.Fragment` (this Decimal version's `Jason.Encoder`
  # would emit a string). No binary floats are ever involved — see the
  # moduledoc for why this is acceptable at this boundary only.
  defp unit_net_price(%Money{} = money) do
    money
    |> Money.to_major_decimal()
    |> Decimal.round(Money.exponent(money.currency))
    |> Decimal.to_string(:normal)
    |> Jason.Fragment.new()
  end

  # -- shared write plumbing --------------------------------------------------

  # A 2xx write response is used directly when it carries the complete
  # document; otherwise the draft is fetched back (SPEC §17.8 steps 7–8).
  defp finalize_draft_write(context, invoice, response_body, known_draft_id \\ nil) do
    draft_id = stringify(response_body["draftInvoiceNumber"]) || stringify(known_draft_id)

    cond do
      complete_payload?(response_body) ->
        {:ok, Normalizer.normalize(response_body, :draft)}

      draft_id != nil ->
        refetch_draft(context, invoice, draft_id)

      true ->
        {:unknown,
         %{
           search_by: [{:external_reference, invoice.external_reference}],
           detail: "write accepted but response lacked draftInvoiceNumber; reconcile"
         }}
    end
  end

  # The write itself succeeded, so a failing read-back is an unknown outcome
  # (the document exists but is unverified), never a plain error that could
  # prompt a duplicate write.
  defp refetch_draft(context, invoice, draft_id) do
    case fetch_document(context, "/invoices/drafts/#{draft_id}", :draft) do
      {:ok, document} ->
        {:ok, document}

      {:error, _reason} ->
        {:unknown,
         %{
           search_by: [
             {:draft, draft_id},
             {:external_reference, invoice.external_reference}
           ],
           detail: "draft #{draft_id} written but read-back failed; reconcile before retry"
         }}
    end
  end

  defp complete_payload?(payload) when is_map(payload) do
    is_list(payload["lines"]) and is_binary(payload["date"]) and
      is_binary(payload["currency"])
  end

  defp complete_payload?(_other), do: false

  defp write_lost_hint(reason, search_refs) do
    %{
      search_by: search_refs,
      detail: "transport #{reason} during write; outcome unknown — reconcile before retry"
    }
  end

  # -- error classification (SPEC §17.13) -------------------------------------

  defp classify(%{status: 401} = response) do
    {:authentication, provider_message(response) || "e-conomic rejected the credentials (401)"}
  end

  defp classify(%{status: 403} = response) do
    {:authorization,
     provider_message(response) || "insufficient agreement/application permissions (403)"}
  end

  defp classify(%{status: status} = response) when status in [400, 422] do
    {:validation, validation_errors(response)}
  end

  defp classify(%{status: 404} = response) do
    {:not_found, provider_message(response) || "resource not found (404)"}
  end

  defp classify(%{status: 409} = response) do
    {:conflict, provider_message(response) || "conflicting document state (409)"}
  end

  defp classify(%{status: 429, headers: headers}) do
    {:rate_limited, %{retry_after: retry_after(headers)}}
  end

  defp classify(%{status: status}), do: {:provider_failure, status}

  defp provider_message(%{body: %{"message" => message}}) when is_binary(message), do: message
  defp provider_message(_response), do: nil

  defp validation_errors(%{body: body} = response) do
    field_errors =
      case body do
        %{"errors" => errors} when is_map(errors) ->
          errors
          |> Enum.flat_map(fn {field, messages} ->
            messages
            |> List.wrap()
            |> Enum.map(&%{field: field, message: error_message(&1)})
          end)
          |> Enum.sort_by(& &1.field)

        %{"errors" => errors} when is_list(errors) ->
          Enum.map(errors, &%{message: error_message(&1)})

        _other ->
          []
      end

    case {field_errors, provider_message(response)} do
      {[], nil} -> [%{message: "validation failed"}]
      {[], message} -> [%{message: message}]
      {errors, _message} -> errors
    end
  end

  defp error_message(%{"message" => message}) when is_binary(message), do: message
  defp error_message(message) when is_binary(message), do: message
  defp error_message(other), do: inspect(other)

  defp retry_after(headers) do
    headers
    |> Map.get("retry-after", [])
    |> List.first()
    |> parse_retry_after()
  end

  defp parse_retry_after(nil), do: nil

  defp parse_retry_after(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {seconds, ""} when seconds >= 0 -> seconds
      _other -> nil
    end
  end

  # -- small helpers ----------------------------------------------------------

  defp put_number_reference(body, _key, _number_key, nil), do: body

  defp put_number_reference(body, key, number_key, id) do
    Map.put(body, key, %{number_key => numberish(id)})
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # e-conomic reference numbers are integers; canonical ids are strings.
  defp numberish(value) when is_integer(value), do: value

  defp numberish(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _other -> value
    end
  end

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_integer(value), do: Integer.to_string(value)
  defp stringify(value), do: to_string(value)

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, _reason} -> nil
    end
  end

  defp parse_date(_other), do: nil
end
