@extends('layouts.app')
@section('content')
<h1>Join {{ $invitation->organization->name }}</h1>
@if ($invitation->isPending())
  <p>You were invited as <strong>{{ $invitation->role }}</strong> ({{ $invitation->email }}).</p>
  <form method="post" action="/invitations/{{ $invitation->token }}" id="accept-invitation-form">@csrf
    <button id="accept-invitation">Accept invitation</button>
  </form>
@else
  <p id="invitation-settled">This invitation is no longer active.</p>
@endif
@endsection
