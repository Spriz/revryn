<?php

namespace Tests\Feature;

use App\Models\Organization;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Http\UploadedFile;
use Tests\TestCase;

class DirectoryFlowTest extends TestCase
{
    use RefreshDatabase;

    private Organization $organization;

    protected function setUp(): void
    {
        parent::setUp();
        $this->post('/register', ['email' => 'hr@example.com', 'password' => 'sikkerhed123']);
        $this->post('/orgs', ['name' => 'Nordlys']);
        $this->organization = Organization::where('name', 'Nordlys')->firstOrFail();
    }

    public function test_hire_assign_manager_custom_fields_and_history(): void
    {
        $slug = $this->organization->slug;
        $this->post("/orgs/{$slug}/departments", ['name' => 'Engineering']);
        $department = $this->organization->departments()->firstOrFail();

        $this->post("/orgs/{$slug}/employees", [
            'full_name' => 'Mette Manager', 'email' => 'mette@example.com',
            'department_id' => $department->id,
        ]);
        $this->post("/orgs/{$slug}/employees", [
            'full_name' => 'Erik Employee', 'email' => 'erik@example.com',
        ]);
        $manager = $this->organization->employees()->where('email', 'mette@example.com')->firstOrFail();
        $employee = $this->organization->employees()->where('email', 'erik@example.com')->firstOrFail();

        // Onboarding checklist scaffolds from the template.
        $this->assertSame(3, $employee->onboardingItems()->count());

        $this->post("/orgs/{$slug}/custom-fields", ['key' => 'tshirt', 'label' => 'T-shirt size']);
        $this->patch("/orgs/{$slug}/employees/{$employee->id}", [
            'manager_id' => $manager->id,
            'custom' => ['tshirt' => 'L', 'not_allowed' => 'x'],
        ]);

        $employee->refresh();
        $this->assertSame($manager->id, $employee->manager_id);
        $this->assertSame(['tshirt' => 'L'], $employee->custom_fields);

        $verbs = $this->organization->changeLogs()->pluck('verb')->all();
        $this->assertContains('employee.hired', $verbs);
        $this->assertContains('employee.updated', $verbs);
    }

    public function test_onboarding_checklist_toggles(): void
    {
        $slug = $this->organization->slug;
        $this->post("/orgs/{$slug}/employees", [
            'full_name' => 'Ny Ansat', 'email' => 'ny@example.com',
        ]);
        $employee = $this->organization->employees()->firstOrFail();
        $item = $employee->onboardingItems()->firstOrFail();

        $this->post("/orgs/{$slug}/employees/{$employee->id}/onboarding/{$item->id}");
        $this->assertNotNull($item->fresh()->completed_at);
        $this->post("/orgs/{$slug}/employees/{$employee->id}/onboarding/{$item->id}");
        $this->assertNull($item->fresh()->completed_at);
    }

    public function test_search_and_csv_round_trip(): void
    {
        $slug = $this->organization->slug;
        $this->post("/orgs/{$slug}/employees", [
            'full_name' => 'Eva Dam', 'email' => 'eva@example.com', 'title' => 'Bogholder',
        ]);
        $this->post("/orgs/{$slug}/employees", [
            'full_name' => 'Anden Person', 'email' => 'anden@example.com',
        ]);

        $this->get("/orgs/{$slug}/employees?q=Bogholder")
            ->assertSee('Eva Dam')->assertDontSee('Anden Person');

        $csv = $this->get("/orgs/{$slug}/employees.csv")->streamedContent();
        $this->assertStringContainsString('eva@example.com', $csv);

        // Idempotent import: re-importing the export creates no duplicates.
        $file = UploadedFile::fake()->createWithContent('employees.csv', $csv);
        $this->post("/orgs/{$slug}/employees/import", ['file' => $file]);
        $this->assertSame(1, $this->organization->employees()->where('email', 'eva@example.com')->count());
    }

    public function test_offboarding_reduces_active_count(): void
    {
        $slug = $this->organization->slug;
        $this->post("/orgs/{$slug}/employees", [
            'full_name' => 'Kort Ansat', 'email' => 'kort@example.com',
        ]);
        $employee = $this->organization->employees()->firstOrFail();
        $this->assertSame(1, $this->organization->activeEmployees());

        $this->post("/orgs/{$slug}/employees/{$employee->id}/offboard");
        $this->assertSame(0, $this->organization->fresh()->activeEmployees());
    }
}
