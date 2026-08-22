<?php

namespace App\Http\Controllers;

use App\Billing\Seam;
use App\Http\Controllers\Concerns\ResolvesOrganization;
use Illuminate\Http\Request;

class BillingController extends Controller
{
    use ResolvesOrganization;

    public function show(string $slug)
    {
        [$organization, $membership] = $this->requireMember($slug);

        return view('billing.show', [
            'organization' => $organization,
            'membership' => $membership,
            'summary' => Seam::provider()->summarize($organization),
        ]);
    }

    public function update(Request $request, string $slug)
    {
        [$organization, $membership] = $this->requireMember($slug);
        abort_unless($membership->isAdmin(), 403);
        $data = $request->validate([
            'minimum_seats' => ['required', 'integer', 'min:1', 'max:10000'],
        ]);
        $organization->update([
            'minimum_seats' => $data['minimum_seats'],
            'onboarding_addon' => $request->boolean('onboarding_addon'),
            'advanced_directory_addon' => $request->boolean('advanced_directory_addon'),
        ]);
        $organization->log(auth()->user(), 'billing.settings_changed', 'Changed billing settings');

        return back();
    }
}
