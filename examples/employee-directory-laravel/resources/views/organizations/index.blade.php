@extends('layouts.app')
@section('content')
<h1>Your organizations</h1>
<ul class="cardlist" id="org-list">
  @forelse ($memberships as $membership)
    <li><a href="/orgs/{{ $membership->organization->slug }}">{{ $membership->organization->name }}</a>
        <span class="muted">{{ $membership->role }}</span></li>
  @empty
    <li id="no-orgs">No organizations yet.</li>
  @endforelse
</ul>
<p><a class="button" id="new-org" href="/orgs/new">New organization</a></p>
@endsection
