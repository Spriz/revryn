@extends('layouts.app')
@section('content')
<h1>{{ $organization->name }}</h1>
<nav class="subnav">
  <a id="org-employees" href="/orgs/{{ $organization->slug }}/employees">Employees</a>
  <a id="org-members" href="/orgs/{{ $organization->slug }}/members">Members</a>
  <a id="org-changelog" href="/orgs/{{ $organization->slug }}/changelog">Change history</a>
  <a id="org-billing" href="/orgs/{{ $organization->slug }}/billing">Billing</a>
</nav>

<h2>Departments</h2>
<ul class="cardlist" id="department-list">
  @foreach ($departments as $department)
    <li>{{ $department->name }} <span class="muted">{{ $department->employees_count }} employees</span></li>
  @endforeach
</ul>
<form method="post" action="/orgs/{{ $organization->slug }}/departments" class="card inlineform">@csrf
  <input name="name" placeholder="New department" required>
  <button id="create-department-submit">Add department</button>
</form>
<form method="post" action="/orgs/{{ $organization->slug }}/locations" class="card inlineform">@csrf
  <input name="name" placeholder="New location" required>
  <input name="city" placeholder="City">
  <button id="create-location-submit">Add location</button>
</form>

@if ($membership->isAdmin())
<h2>Configuration</h2>
<form method="post" action="/orgs/{{ $organization->slug }}/custom-fields" class="card inlineform" id="custom-field-form">@csrf
  <input name="key" placeholder="field_key" required>
  <input name="label" placeholder="Field label" required>
  <button id="create-field-submit">Add custom field</button>
</form>
<form method="post" action="/orgs/{{ $organization->slug }}/onboarding-tasks" class="card inlineform" id="onboarding-task-form">@csrf
  <input name="title" placeholder="New onboarding checklist item" required>
  <button id="create-task-submit">Add checklist item</button>
</form>
@endif

<h2>Recent changes</h2>
<ul class="cardlist" id="recent-changes">
  @foreach ($recent as $row)
    <li><span class="muted">{{ $row->created_at->format('Y-m-d H:i') }}</span>
        <strong>{{ $row->actor?->email }}</strong> {{ $row->summary }}</li>
  @endforeach
</ul>
@endsection
