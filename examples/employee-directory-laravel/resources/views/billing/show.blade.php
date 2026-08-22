@extends('layouts.app')
@section('content')
<h1>{{ $organization->name }} · Billing</h1>
<p class="muted">Standalone showcase fixtures — served through the application-local billing seam.
   Annual prepaid per active employee with a minimum commitment.</p>
<div class="grid2">
<section class="card" id="seats-card">
  <h2>Employees</h2>
  <p><strong id="active-employees">{{ $summary['active_employees'] }}</strong> active ·
     minimum <span id="minimum-seats">{{ $summary['minimum_seats'] }}</span> ·
     billable <strong id="billable-seats">{{ $summary['billable_seats'] }}</strong></p>
  <p>Annual seat total: <strong id="seat-total">{{ \App\Billing\Seam::formatOre($summary['seat_total_ore']) }}</strong></p>
  <p class="muted">Mid-term growth prorates prospectively:
     <span id="prospective-growth">{{ \App\Billing\Seam::formatOre($summary['prospective_growth_ore']) }}</span>
     for seats above the commitment added today.</p>
</section>
<section class="card" id="addons-card">
  <h2>Add-ons</h2>
  <p>Total: <strong id="addon-total">{{ \App\Billing\Seam::formatOre($summary['addon_total_ore']) }}</strong></p>
  @if ($membership->isAdmin())
    <form method="post" action="/orgs/{{ $organization->slug }}/billing" id="billing-settings-form">
      @csrf @method('PATCH')
      <label>Minimum seat commitment
        <input type="number" name="minimum_seats" min="1" value="{{ $organization->minimum_seats }}">
      </label>
      <label><input type="checkbox" name="onboarding_addon" value="1" @checked($organization->onboarding_addon)> Onboarding workflows</label>
      <label><input type="checkbox" name="advanced_directory_addon" value="1" @checked($organization->advanced_directory_addon)> Advanced directory</label>
      <button id="billing-save">Save</button>
    </form>
  @endif
</section>
</div>
<p class="big">Annual total: <strong id="year-total">{{ \App\Billing\Seam::formatOre($summary['year_total_ore']) }}</strong></p>

@if (isset($summary['preview_lines']))
  <section class="card" id="preview-traceability">
    <h2>Billing Core invoice preview</h2>
    <p class="muted">Live from the platform — fingerprint <code id="preview-fingerprint">{{ $summary['preview_fingerprint'] }}</code></p>
    <table class="table" id="preview-lines">
      <thead><tr><th>Line</th><th>Description</th><th>Qty</th><th>Amount (minor)</th></tr></thead>
      <tbody>
        @foreach ($summary['preview_lines'] as $line)
          <tr><td class="muted">{{ $line['lineKey'] }}</td><td>{{ $line['description'] }}</td>
              <td>{{ $line['quantity'] }}</td><td>{{ $line['amountMinor'] }}</td></tr>
        @endforeach
      </tbody>
    </table>
  </section>
@endif
@endsection
