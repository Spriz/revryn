@extends('layouts.app')
@section('content')
<h1 id="employee-name">{{ $employee->full_name }}</h1>
<p class="muted">{{ $employee->title }} · {{ $employee->email }}
   · status <strong id="employee-status">{{ $employee->status }}</strong></p>
<p><a href="/orgs/{{ $organization->slug }}/employees">&larr; Directory</a></p>

<div class="grid2">
<section class="card">
  <h2>Profile</h2>
  <form method="post" action="/orgs/{{ $organization->slug }}/employees/{{ $employee->id }}" id="profile-form">
    @csrf @method('PATCH')
    <label>Title <input name="title" value="{{ $employee->title }}"></label>
    <label>Department
      <select name="department_id"><option value="">—</option>
        @foreach ($departments as $department)<option value="{{ $department->id }}" @selected($employee->department_id === $department->id)>{{ $department->name }}</option>@endforeach
      </select>
    </label>
    <label>Location
      <select name="location_id"><option value="">—</option>
        @foreach ($locations as $location)<option value="{{ $location->id }}" @selected($employee->location_id === $location->id)>{{ $location->name }}</option>@endforeach
      </select>
    </label>
    <label>Manager
      <select name="manager_id"><option value="">—</option>
        @foreach ($managers as $manager)<option value="{{ $manager->id }}" @selected($employee->manager_id === $manager->id)>{{ $manager->full_name }}</option>@endforeach
      </select>
    </label>
    @foreach ($fieldDefs as $field)
      <label>{{ $field->label }}
        <input name="custom[{{ $field->key }}]" value="{{ $employee->custom_fields[$field->key] ?? '' }}">
      </label>
    @endforeach
    <button id="profile-save">Save</button>
  </form>
  @if ($employee->status === 'active')
    <form method="post" action="/orgs/{{ $organization->slug }}/employees/{{ $employee->id }}/offboard" class="inline">@csrf
      <button class="danger" id="offboard">Offboard</button>
    </form>
  @endif
  @if ($employee->reports->isNotEmpty())
    <h2>Reports</h2>
    <ul id="report-list">
      @foreach ($employee->reports as $report)<li>{{ $report->full_name }}</li>@endforeach
    </ul>
  @endif
</section>

<section class="card">
  <h2>Onboarding checklist</h2>
  <ul class="cardlist" id="onboarding-list">
    @foreach ($employee->onboardingItems as $item)
      <li class="{{ $item->completed_at ? 'done' : '' }}">
        <form method="post" action="/orgs/{{ $organization->slug }}/employees/{{ $employee->id }}/onboarding/{{ $item->id }}" class="inline">@csrf
          <button class="linklike">{{ $item->completed_at ? '☑' : '☐' }}</button>
        </form>
        {{ $item->task->title }}
      </li>
    @endforeach
  </ul>
</section>
</div>
@endsection
