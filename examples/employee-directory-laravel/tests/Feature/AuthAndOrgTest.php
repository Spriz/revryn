<?php

namespace Tests\Feature;

use App\Models\Organization;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

class AuthAndOrgTest extends TestCase
{
    use RefreshDatabase;

    private function register(string $email = 'anna@example.com'): User
    {
        $this->post('/register', [
            'email' => $email, 'password' => 'sikkerhed123', 'name' => 'Anna',
        ]);

        return User::where('email', $email)->firstOrFail();
    }

    public function test_register_signs_in_and_lands_home(): void
    {
        $response = $this->post('/register', [
            'email' => 'ny@example.com', 'password' => 'sikkerhed123',
        ]);
        $response->assertRedirect('/');
        $this->assertAuthenticated();
    }

    public function test_login_rejects_wrong_password(): void
    {
        $this->register();
        auth()->logout();
        $response = $this->post('/login', [
            'email' => 'anna@example.com', 'password' => 'forkert',
        ]);
        $response->assertSessionHasErrors('email');
    }

    public function test_creating_an_organization_scaffolds_checklist_and_owner_role(): void
    {
        $user = $this->register();
        $this->post('/orgs', ['name' => 'Personalehuset ApS']);
        $organization = Organization::where('name', 'Personalehuset ApS')->firstOrFail();

        $this->assertSame('owner', $organization->roleOf($user));
        $this->assertSame(3, $organization->onboardingTasks()->count());
    }

    public function test_last_owner_cannot_be_demoted_or_removed(): void
    {
        $this->register();
        $this->post('/orgs', ['name' => 'Solo']);
        $organization = Organization::where('name', 'Solo')->firstOrFail();
        $membership = $organization->memberships()->first();

        $this->patch("/orgs/{$organization->slug}/members/{$membership->id}", ['role' => 'member']);
        $this->assertSame('owner', $membership->fresh()->role);

        $this->delete("/orgs/{$organization->slug}/members/{$membership->id}");
        $this->assertSame('active', $membership->fresh()->status);
    }

    public function test_non_members_get_403(): void
    {
        $this->register();
        $this->post('/orgs', ['name' => 'Privat']);
        $organization = Organization::where('name', 'Privat')->firstOrFail();

        auth()->logout();
        $this->register('fremmed@example.com');
        $this->get("/orgs/{$organization->slug}")->assertForbidden();
        $this->get("/orgs/{$organization->slug}/employees")->assertForbidden();
    }
}
