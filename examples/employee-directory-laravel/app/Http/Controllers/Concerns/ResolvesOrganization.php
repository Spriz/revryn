<?php

namespace App\Http\Controllers\Concerns;

use App\Models\Membership;
use App\Models\Organization;

trait ResolvesOrganization
{
    protected function organization(string $slug): Organization
    {
        return Organization::where('slug', $slug)->firstOrFail();
    }

    protected function membership(Organization $organization): ?Membership
    {
        return $organization->memberships()
            ->where('user_id', auth()->id())->where('status', 'active')->first();
    }

    /** @return array{0: Organization, 1: Membership} */
    protected function requireMember(string $slug): array
    {
        $organization = $this->organization($slug);
        $membership = $this->membership($organization);
        abort_unless($membership, 403);

        return [$organization, $membership];
    }
}
