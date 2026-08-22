<?php

namespace Tests\Feature;

use App\Models\Invitation;
use App\Models\Organization;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Hash;
use Tests\TestCase;

class InvitationTest extends TestCase
{
    use RefreshDatabase;

    private Organization $organization;

    protected function setUp(): void
    {
        parent::setUp();
        $this->post('/register', ['email' => 'ejer@example.com', 'password' => 'sikkerhed123']);
        $this->post('/orgs', ['name' => 'Havblik']);
        $this->organization = Organization::where('name', 'Havblik')->firstOrFail();
    }

    public function test_invitation_is_email_bound_and_single_use(): void
    {
        $invitation = $this->organization->invitations()->create(['email' => 'gaest@example.com']);

        $wrong = User::create([
            'name' => 'x', 'email' => 'forkert@example.com', 'password' => Hash::make('sikkerhed123'),
        ]);
        $this->expectException(\InvalidArgumentException::class);
        $invitation->accept($wrong);
    }

    public function test_accept_flow_grants_the_invited_role_once(): void
    {
        $this->post("/orgs/{$this->organization->slug}/invitations", [
            'email' => 'med@example.com', 'role' => 'admin',
        ]);
        $invitation = Invitation::where('email', 'med@example.com')->firstOrFail();

        auth()->logout();
        $this->post('/register', ['email' => 'med@example.com', 'password' => 'sikkerhed123']);
        $this->post("/invitations/{$invitation->token}")
            ->assertRedirect("/orgs/{$this->organization->slug}");

        $invitee = User::where('email', 'med@example.com')->firstOrFail();
        $this->assertSame('admin', $this->organization->roleOf($invitee));
        $this->assertNotNull($invitation->fresh()->accepted_at);
    }
}
