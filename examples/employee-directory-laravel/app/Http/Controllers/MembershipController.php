<?php

namespace App\Http\Controllers;

use App\Http\Controllers\Concerns\ResolvesOrganization;
use App\Models\Invitation;
use App\Models\Membership;
use Illuminate\Http\Request;

class MembershipController extends Controller
{
    use ResolvesOrganization;

    public function index(string $slug)
    {
        [$organization, $membership] = $this->requireMember($slug);

        return view('members.index', [
            'organization' => $organization,
            'myMembership' => $membership,
            'memberships' => $organization->memberships()
                ->where('status', 'active')->with('user')->orderBy('created_at')->get(),
            'invitations' => $organization->invitations()->latest()->get(),
        ]);
    }

    public function update(Request $request, string $slug, int $membershipId)
    {
        [$organization, $mine] = $this->requireMember($slug);
        abort_unless($mine->isAdmin(), 403);
        $target = $organization->memberships()->where('status', 'active')->findOrFail($membershipId);
        $role = $request->string('role')->toString();
        $owners = $organization->memberships()->where('status', 'active')->where('role', 'owner')->count();

        if (! in_array($role, Membership::ROLES, true)) {
            return back()->withErrors(['role' => 'Unknown role.']);
        }
        if ($target->role === 'owner' && $role !== 'owner' && $owners <= 1) {
            return back()->withErrors(['role' => 'The last owner cannot be demoted.']);
        }
        $target->update(['role' => $role]);
        $organization->log(auth()->user(), 'member.role_changed', "{$target->user->email} is now {$role}");

        return back();
    }

    public function destroy(string $slug, int $membershipId)
    {
        [$organization, $mine] = $this->requireMember($slug);
        abort_unless($mine->isAdmin(), 403);
        $target = $organization->memberships()->where('status', 'active')->findOrFail($membershipId);
        $owners = $organization->memberships()->where('status', 'active')->where('role', 'owner')->count();
        if ($target->role === 'owner' && $owners <= 1) {
            return back()->withErrors(['role' => 'The last owner cannot be removed.']);
        }
        $target->update(['status' => 'removed']);
        $organization->log(auth()->user(), 'member.removed', "Removed {$target->user->email}");

        return back();
    }

    public function invite(Request $request, string $slug)
    {
        [$organization, $mine] = $this->requireMember($slug);
        abort_unless($mine->isAdmin(), 403);
        $data = $request->validate([
            'email' => ['required', 'email'],
            'role' => ['required', 'in:owner,admin,member'],
        ]);
        $invitation = $organization->invitations()->create([
            'email' => strtolower($data['email']),
            'role' => $data['role'],
        ]);
        $organization->log(auth()->user(), 'member.invited', "Invited {$invitation->email} as {$invitation->role}");

        return back()->with('status', 'Share this single-use link: '.url("/invitations/{$invitation->token}"));
    }

    public function revokeInvitation(string $slug, int $invitationId)
    {
        [$organization, $mine] = $this->requireMember($slug);
        abort_unless($mine->isAdmin(), 403);
        $invitation = $organization->invitations()->findOrFail($invitationId);
        if ($invitation->isPending()) {
            $invitation->forceFill(['revoked_at' => now()])->save();
        }

        return back();
    }

    public function showInvitation(string $token)
    {
        $invitation = Invitation::where('token', $token)->firstOrFail();

        return view('members.invitation', ['invitation' => $invitation]);
    }

    public function acceptInvitation(string $token)
    {
        $invitation = Invitation::where('token', $token)->firstOrFail();
        try {
            $invitation->accept(auth()->user());
        } catch (\InvalidArgumentException $error) {
            return redirect('/')->withErrors(['invitation' => $error->getMessage()]);
        }
        $invitation->organization->log(auth()->user(), 'member.joined',
            auth()->user()->email." joined as {$invitation->role}");

        return redirect('/orgs/'.$invitation->organization->slug);
    }
}
