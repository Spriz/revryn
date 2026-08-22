@extends('layouts.app')
@section('content')
<h1>{{ $organization->name }} · Employees</h1>
<p><a href="/orgs/{{ $organization->slug }}">&larr; Back</a>
   · <a id="export-csv" href="/orgs/{{ $organization->slug }}/employees.csv">Export CSV</a></p>

<form method="get" action="/orgs/{{ $organization->slug }}/employees" id="search-form" class="card inlineform">
  <input name="q" value="{{ $search }}" placeholder="Search name, email, title…">
  <button id="search-submit">Search</button>
</form>

<form method="post" action="/orgs/{{ $organization->slug }}/employees" id="new-employee-form" class="card inlineform">@csrf
  <input name="full_name" placeholder="Full name" required>
  <input name="email" type="email" placeholder="email" required>
  <input name="title" placeholder="title">
  <select name="department_id"><option value="">No department</option>
    @foreach ($departments as $department)<option value="{{ $department->id }}">{{ $department->name }}</option>@endforeach
  </select>
  <select name="location_id"><option value="">No location</option>
    @foreach ($locations as $location)<option value="{{ $location->id }}">{{ $location->name }}</option>@endforeach
  </select>
  <input name="started_on" type="date">
  <button id="create-employee-submit">Hire</button>
</form>

<form method="post" action="/orgs/{{ $organization->slug }}/employees/import" enctype="multipart/form-data" id="import-form" class="card inlineform">@csrf
  <input type="file" name="file" accept=".csv" required>
  <button id="import-submit">Import CSV</button>
</form>

<table class="table" id="employee-list">
  <thead><tr><th>Name</th><th>Title</th><th>Department</th><th>Manager</th><th>Status</th></tr></thead>
  <tbody>
    @foreach ($employees as $employee)
      <tr>
        <td><a href="/orgs/{{ $organization->slug }}/employees/{{ $employee->id }}">{{ $employee->full_name }}</a>
            <span class="muted">{{ $employee->email }}</span></td>
        <td>{{ $employee->title }}</td>
        <td>{{ $employee->department?->name }}</td>
        <td>{{ $employee->manager?->full_name }}</td>
        <td>{{ $employee->status }}</td>
      </tr>
    @endforeach
  </tbody>
</table>
@endsection
