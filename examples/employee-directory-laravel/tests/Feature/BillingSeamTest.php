<?php

namespace Tests\Feature;

use App\Billing\Seam;
use App\Models\Organization;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

class BillingSeamTest extends TestCase
{
    use RefreshDatabase;

    private Organization $organization;

    protected function setUp(): void
    {
        parent::setUp();
        $this->post('/register', ['email' => 'hr@example.com', 'password' => 'sikkerhed123']);
        $this->post('/orgs', ['name' => 'Seam']);
        $this->organization = Organization::where('name', 'Seam')->firstOrFail();
    }

    private function hire(int $count): void
    {
        for ($n = 0; $n < $count; $n++) {
            $this->organization->employees()->create([
                'full_name' => "Ansat {$n}", 'email' => "a{$n}@example.com",
            ]);
        }
    }

    public function test_minimum_commitment_floors_the_billable_seats(): void
    {
        $this->hire(2); // below the default minimum of 5
        $summary = Seam::provider()->summarize($this->organization->fresh());

        $this->assertSame(2, $summary['active_employees']);
        $this->assertSame(5, $summary['billable_seats']);
        $this->assertSame(5 * Seam::PER_EMPLOYEE_YEAR_ORE, $summary['seat_total_ore']);
        $this->assertSame(0, $summary['prospective_growth_ore']);
    }

    public function test_growth_beyond_the_minimum_prorates_prospectively(): void
    {
        $this->hire(7);
        $summary = Seam::provider()->summarize($this->organization->fresh());

        $this->assertSame(7, $summary['billable_seats']);
        $dayOfYear = (int) now()->format('z');
        $expected = (int) floor(2 * Seam::PER_EMPLOYEE_YEAR_ORE * ((365 - $dayOfYear) / 365));
        $this->assertSame($expected, $summary['prospective_growth_ore']);
    }

    public function test_addons_are_flat_annual_amounts(): void
    {
        $this->organization->update(['onboarding_addon' => true, 'advanced_directory_addon' => true]);
        $summary = Seam::provider()->summarize($this->organization->fresh());

        $this->assertSame(
            Seam::ONBOARDING_ADDON_YEAR_ORE + Seam::ADVANCED_ADDON_YEAR_ORE,
            $summary['addon_total_ore'],
        );
    }

    public function test_admin_billing_settings_form_updates_the_fixtures(): void
    {
        $slug = $this->organization->slug;
        $this->patch("/orgs/{$slug}/billing", [
            'minimum_seats' => 10, 'onboarding_addon' => '1',
        ]);
        $this->organization->refresh();
        $this->assertSame(10, $this->organization->minimum_seats);
        $this->assertTrue((bool) $this->organization->onboarding_addon);
        $this->assertFalse((bool) $this->organization->advanced_directory_addon);
    }

    public function test_format_ore_uses_integer_minor_units(): void
    {
        $this->assertSame('12,345.01 DKK', Seam::formatOre(1_234_501));
    }
}
