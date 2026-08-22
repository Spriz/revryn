<?php

namespace App\Http\Controllers;

use App\Http\Controllers\Concerns\ResolvesOrganization;
use App\Models\Membership;
use App\Models\Organization;
use Illuminate\Http\Request;
use Illuminate\Support\Str;

class OrganizationController extends Controller
{
    use ResolvesOrganization;

    public function index()
    {
        $memberships = auth()->user()->memberships()
            ->where('status', 'active')->with('organization')->get();

        return view('organizations.index', ['memberships' => $memberships]);
    }

    public function create()
    {
        return view('organizations.create');
    }

    public function store(Request $request)
    {
        $data = $request->validate(['name' => ['required', 'string', 'max:200']]);
        $base = Str::slug($data['name']) ?: 'org';
        $slug = $base;
        for ($n = 2; Organization::where('slug', $slug)->exists(); $n++) {
            $slug = "$base-$n";
        }

        $organization = Organization::create(['name' => $data['name'], 'slug' => $slug]);
        $organization->memberships()->create(['user_id' => auth()->id(), 'role' => 'owner']);
        foreach (['Sign employment contract', 'Order laptop', 'Grant system access'] as $position => $title) {
            $organization->onboardingTasks()->create(['title' => $title, 'position' => $position]);
        }
        $organization->log(auth()->user(), 'org.created', "Created organization {$data['name']}");

        return redirect("/orgs/{$slug}");
    }

    public function show(string $slug)
    {
        [$organization, $membership] = $this->requireMember($slug);

        return view('organizations.show', [
            'organization' => $organization,
            'membership' => $membership,
            'departments' => $organization->departments()->withCount('employees')->orderBy('name')->get(),
            'recent' => $organization->changeLogs()->with('actor')->limit(8)->get(),
        ]);
    }
}
