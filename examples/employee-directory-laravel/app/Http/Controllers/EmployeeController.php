<?php

namespace App\Http\Controllers;

use App\Http\Controllers\Concerns\ResolvesOrganization;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\StreamedResponse;

class EmployeeController extends Controller
{
    use ResolvesOrganization;

    public function index(Request $request, string $slug)
    {
        [$organization] = $this->requireMember($slug);
        $query = $organization->employees()->with(['department', 'location', 'manager']);

        if ($search = trim($request->string('q')->toString())) {
            $query->where(function ($where) use ($search) {
                $like = '%'.str_replace(['%', '_'], ['\%', '\_'], $search).'%';
                $where->where('full_name', 'like', $like)
                    ->orWhere('email', 'like', $like)
                    ->orWhere('title', 'like', $like);
            });
        }

        return view('employees.index', [
            'organization' => $organization,
            'employees' => $query->orderBy('full_name')->limit(200)->get(),
            'departments' => $organization->departments()->orderBy('name')->get(),
            'locations' => $organization->locations()->orderBy('name')->get(),
            'search' => $search ?? '',
        ]);
    }

    public function store(Request $request, string $slug)
    {
        [$organization] = $this->requireMember($slug);
        $data = $request->validate([
            'full_name' => ['required', 'string', 'max:200'],
            'email' => ['required', 'email'],
            'title' => ['nullable', 'string', 'max:200'],
            'department_id' => ['nullable', 'integer'],
            'location_id' => ['nullable', 'integer'],
            'started_on' => ['nullable', 'date'],
        ]);

        $employee = $organization->employees()->create([
            'full_name' => $data['full_name'],
            'email' => strtolower($data['email']),
            'title' => $data['title'] ?? '',
            'department_id' => ($data['department_id'] ?? null)
                ? $organization->departments()->findOrFail($data['department_id'])->id : null,
            'location_id' => ($data['location_id'] ?? null)
                ? $organization->locations()->findOrFail($data['location_id'])->id : null,
            'started_on' => $data['started_on'] ?? null,
        ]);
        foreach ($organization->onboardingTasks as $task) {
            $employee->onboardingItems()->create(['onboarding_task_id' => $task->id]);
        }
        $organization->log(auth()->user(), 'employee.hired', "Hired {$employee->full_name}");

        return redirect("/orgs/{$slug}/employees/{$employee->id}");
    }

    public function show(string $slug, int $employeeId)
    {
        [$organization, $membership] = $this->requireMember($slug);
        $employee = $organization->employees()
            ->with(['department', 'location', 'manager', 'reports', 'onboardingItems.task'])
            ->findOrFail($employeeId);

        return view('employees.show', [
            'organization' => $organization,
            'membership' => $membership,
            'employee' => $employee,
            'departments' => $organization->departments()->orderBy('name')->get(),
            'locations' => $organization->locations()->orderBy('name')->get(),
            'managers' => $organization->employees()->where('status', 'active')
                ->where('id', '!=', $employee->id)->orderBy('full_name')->get(),
            'fieldDefs' => $organization->customFieldDefs()->orderBy('key')->get(),
        ]);
    }

    public function update(Request $request, string $slug, int $employeeId)
    {
        [$organization] = $this->requireMember($slug);
        $employee = $organization->employees()->findOrFail($employeeId);

        $data = $request->validate([
            'title' => ['nullable', 'string', 'max:200'],
            'department_id' => ['nullable', 'integer'],
            'location_id' => ['nullable', 'integer'],
            'manager_id' => ['nullable', 'integer'],
            'custom' => ['nullable', 'array'],
        ]);

        $custom = $employee->custom_fields ?? [];
        $allowed = $organization->customFieldDefs()->pluck('key')->all();
        foreach (($data['custom'] ?? []) as $key => $value) {
            if (in_array($key, $allowed, true)) {
                $custom[$key] = (string) $value;
            }
        }

        $employee->update([
            'title' => $data['title'] ?? $employee->title,
            'department_id' => ($data['department_id'] ?? null)
                ? $organization->departments()->findOrFail($data['department_id'])->id
                : $employee->department_id,
            'location_id' => ($data['location_id'] ?? null)
                ? $organization->locations()->findOrFail($data['location_id'])->id
                : $employee->location_id,
            'manager_id' => ($data['manager_id'] ?? null)
                ? $organization->employees()->findOrFail($data['manager_id'])->id
                : null,
            'custom_fields' => $custom,
        ]);
        $organization->log(auth()->user(), 'employee.updated', "Updated {$employee->full_name}");

        return back();
    }

    public function offboard(string $slug, int $employeeId)
    {
        [$organization] = $this->requireMember($slug);
        $employee = $organization->employees()->findOrFail($employeeId);
        $employee->update(['status' => 'offboarded']);
        $organization->log(auth()->user(), 'employee.offboarded', "Offboarded {$employee->full_name}");

        return back();
    }

    public function toggleOnboarding(string $slug, int $employeeId, int $itemId)
    {
        [$organization] = $this->requireMember($slug);
        $employee = $organization->employees()->findOrFail($employeeId);
        $item = $employee->onboardingItems()->findOrFail($itemId);
        $item->forceFill(['completed_at' => $item->completed_at ? null : now()])->save();

        return back();
    }

    public function exportCsv(string $slug): StreamedResponse
    {
        [$organization] = $this->requireMember($slug);
        $employees = $organization->employees()->with(['department', 'location'])->orderBy('full_name')->get();

        return response()->streamDownload(function () use ($employees) {
            $out = fopen('php://output', 'w');
            fputcsv($out, ['full_name', 'email', 'title', 'department', 'location', 'status']);
            foreach ($employees as $employee) {
                fputcsv($out, [
                    $employee->full_name, $employee->email, $employee->title,
                    $employee->department?->name, $employee->location?->name, $employee->status,
                ]);
            }
            fclose($out);
        }, 'employees.csv', ['Content-Type' => 'text/csv']);
    }

    public function importCsv(Request $request, string $slug)
    {
        [$organization] = $this->requireMember($slug);
        $request->validate(['file' => ['required', 'file']]);

        $handle = fopen($request->file('file')->getRealPath(), 'r');
        $header = fgetcsv($handle) ?: [];
        $imported = 0;
        while (($row = fgetcsv($handle)) !== false) {
            $data = array_combine($header, array_pad($row, count($header), null));
            if (empty($data['email'])) {
                continue;
            }
            $department = ! empty($data['department'])
                ? $organization->departments()->firstOrCreate(['name' => trim($data['department'])])
                : null;
            $organization->employees()->updateOrCreate(
                ['email' => strtolower(trim($data['email']))],
                [
                    'full_name' => trim($data['full_name'] ?? '') ?: $data['email'],
                    'title' => trim($data['title'] ?? ''),
                    'department_id' => $department?->id,
                ],
            );
            $imported++;
        }
        fclose($handle);
        $organization->log(auth()->user(), 'employee.imported', "Imported {$imported} employees from CSV");

        return back()->with('status', "Imported {$imported} employees.");
    }
}
