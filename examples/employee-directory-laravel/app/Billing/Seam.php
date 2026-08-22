<?php

namespace App\Billing;

use App\Models\Organization;

/**
 * The application-local billing seam (BC-US-152, INV-030/031).
 *
 * Every plan/entitlement question goes through Seam::provider() and
 * nothing else; standalone answers come from the fixtures below, and the
 * future Billing Core integration swaps the provider without touching a
 * single caller. Amounts are integer oere — never floats.
 *
 * Billing model: ANNUAL PREPAID per active employee with a minimum seat
 * commitment; optional onboarding-workflows and advanced-directory
 * add-ons; mid-term employee growth prorates prospectively (the summary
 * exposes the prospective-proration amount for seats added mid-term).
 */
final class Seam
{
    public const PER_EMPLOYEE_YEAR_ORE = 59_900;      // per active employee per year
    public const ONBOARDING_ADDON_YEAR_ORE = 99_000;  // flat per year
    public const ADVANCED_ADDON_YEAR_ORE = 149_000;   // flat per year
    public const CURRENCY = 'DKK';

    private static ?object $provider = null;

    public static function provider(): object
    {
        if (\App\BillingCore\Integration::enabled()) {
            return self::$provider ??= new \App\BillingCore\Provider();
        }

        return self::$provider ??= new LocalFixtureProvider();
    }

    public static function swapProvider(object $provider): void
    {
        self::$provider = $provider;
    }

    public static function formatOre(int $ore): string
    {
        $major = intdiv($ore, 100);
        $minor = $ore % 100;

        return number_format($major).'.'.str_pad((string) $minor, 2, '0', STR_PAD_LEFT).' '.self::CURRENCY;
    }
}

final class LocalFixtureProvider
{
    public function summarize(Organization $organization): array
    {
        $active = $organization->activeEmployees();
        $billable = max($active, $organization->minimum_seats);
        $seats = $billable * Seam::PER_EMPLOYEE_YEAR_ORE;
        $addons = ($organization->onboarding_addon ? Seam::ONBOARDING_ADDON_YEAR_ORE : 0)
            + ($organization->advanced_directory_addon ? Seam::ADVANCED_ADDON_YEAR_ORE : 0);

        // Mid-term growth prorates prospectively: seats above the minimum
        // added today are charged for the remaining fraction of the year.
        $dayOfYear = (int) now()->format('z');
        $remainingFraction = (365 - $dayOfYear) / 365;
        $growth = max($active - $organization->minimum_seats, 0);
        $prospective = (int) floor($growth * Seam::PER_EMPLOYEE_YEAR_ORE * $remainingFraction);

        return [
            'active_employees' => $active,
            'minimum_seats' => $organization->minimum_seats,
            'billable_seats' => $billable,
            'seat_total_ore' => $seats,
            'addon_total_ore' => $addons,
            'prospective_growth_ore' => $prospective,
            'year_total_ore' => $seats + $addons,
            'currency' => Seam::CURRENCY,
        ];
    }
}
