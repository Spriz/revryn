<?php

namespace App\BillingCore;

use App\Billing\Seam;
use App\Models\Organization;

/**
 * Billing Core-backed seam provider: the annual seat total comes LIVE
 * from the platform invoice preview with fingerprint + line traceability
 * (BC-US-152 "service-period propagation for annual prepaid lines" is
 * certified in the integrated run against the frozen intent).
 */
final class Provider
{
    public function __construct(private ?Client $client = null)
    {
        $this->client ??= new Client();
    }

    public function summarize(Organization $organization): array
    {
        $link = Provisioning::ensureProvisioned($organization, $this->client);
        $preview = $this->client->execute(
            'query($t: ID!, $s: ID!, $d: Date!){ invoicePreview(teamId: $t, subscriptionId: $s, asOf: $d) { netAmountMinor fingerprint lines { lineKey description quantity amountMinor serviceStart serviceEndExclusive } } }',
            ['t' => $this->client->teamId, 's' => $link->subscription_ref, 'd' => now()->toDateString()],
        )['invoicePreview'];

        $active = $organization->activeEmployees();
        $billable = Provisioning::billableSeats($organization);
        $seats = array_sum(array_column($preview['lines'], 'amountMinor'));
        $addons = ($organization->onboarding_addon ? Seam::ONBOARDING_ADDON_YEAR_ORE : 0)
            + ($organization->advanced_directory_addon ? Seam::ADVANCED_ADDON_YEAR_ORE : 0);

        return [
            'active_employees' => $active,
            'minimum_seats' => $organization->minimum_seats,
            'billable_seats' => $billable,
            'seat_total_ore' => $seats,
            'addon_total_ore' => $addons,
            'prospective_growth_ore' => 0,
            'year_total_ore' => $seats + $addons,
            'currency' => Seam::CURRENCY,
            'preview_lines' => $preview['lines'],
            'preview_fingerprint' => $preview['fingerprint'],
        ];
    }
}
