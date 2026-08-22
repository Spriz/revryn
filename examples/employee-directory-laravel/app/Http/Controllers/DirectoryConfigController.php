<?php

namespace App\Http\Controllers;

use App\Http\Controllers\Concerns\ResolvesOrganization;
use Illuminate\Http\Request;

class DirectoryConfigController extends Controller
{
    use ResolvesOrganization;

    public function storeDepartment(Request $request, string $slug)
    {
        [$organization] = $this->requireMember($slug);
        $data = $request->validate(['name' => ['required', 'string', 'max:120']]);
        $organization->departments()->firstOrCreate(['name' => $data['name']]);

        return back();
    }

    public function storeLocation(Request $request, string $slug)
    {
        [$organization] = $this->requireMember($slug);
        $data = $request->validate([
            'name' => ['required', 'string', 'max:120'],
            'city' => ['nullable', 'string', 'max:120'],
        ]);
        $organization->locations()->create(['name' => $data['name'], 'city' => $data['city'] ?? '']);

        return back();
    }

    public function storeCustomField(Request $request, string $slug)
    {
        [$organization, $membership] = $this->requireMember($slug);
        abort_unless($membership->isAdmin(), 403);
        $data = $request->validate([
            'key' => ['required', 'alpha_dash', 'max:60'],
            'label' => ['required', 'string', 'max:120'],
        ]);
        $organization->customFieldDefs()->firstOrCreate(['key' => $data['key']], ['label' => $data['label']]);

        return back();
    }

    public function storeOnboardingTask(Request $request, string $slug)
    {
        [$organization, $membership] = $this->requireMember($slug);
        abort_unless($membership->isAdmin(), 403);
        $data = $request->validate(['title' => ['required', 'string', 'max:200']]);
        $organization->onboardingTasks()->create([
            'title' => $data['title'],
            'position' => $organization->onboardingTasks()->count(),
        ]);

        return back();
    }

    public function changeLog(string $slug)
    {
        [$organization] = $this->requireMember($slug);

        return view('changelog.index', [
            'organization' => $organization,
            'rows' => $organization->changeLogs()->with('actor')->limit(200)->get(),
        ]);
    }
}
