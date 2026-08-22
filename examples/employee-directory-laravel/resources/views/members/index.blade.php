@extends('layouts.app')
@section('content')
<h1>{{ $organization->name }} · Members</h1>
<p><a href="/orgs/{{ $organization->slug }}">&larr; Back</a></p>
<table class="table" id="members-table">
  <thead><tr><th>Member</th><th>Role</th><th></th></tr></thead>
  <tbody>
    @foreach ($memberships as $membership)
      <tr id="member-{{ $membership->id }}">
        <td>{{ $membership->user->name }} <span class="muted">{{ $membership->user->email }}</span></td>
        <td>
          @if ($myMembership->isAdmin())
            <form method="post" action="/orgs/{{ $organization->slug }}/members/{{ $membership->id }}" class="inline">
              @csrf @method('PATCH')
              <select name="role" onchange="this.form.submit()">
                @foreach (\App\Models\Membership::ROLES as $role)
                  <option value="{{ $role }}" @selected($membership->role === $role)>{{ $role }}</option>
                @endforeach
              </select>
            </form>
          @else
            {{ $membership->role }}
          @endif
        </td>
        <td>
          @if ($myMembership->isAdmin() && $membership->id !== $myMembership->id)
            <form method="post" action="/orgs/{{ $organization->slug }}/members/{{ $membership->id }}" class="inline">
              @csrf @method('DELETE')<button class="danger">Remove</button>
            </form>
          @endif
        </td>
      </tr>
    @endforeach
  </tbody>
</table>

@if ($myMembership->isAdmin())
<h2>Invite</h2>
<form method="post" action="/orgs/{{ $organization->slug }}/invitations" id="invite-form" class="card">@csrf
  <label>Email <input type="email" name="email" required></label>
  <label>Role
    <select name="role">@foreach (\App\Models\Membership::ROLES as $role)<option value="{{ $role }}">{{ $role }}</option>@endforeach</select>
  </label>
  <button id="invite-submit">Create invitation link</button>
</form>

<h2>Invitations</h2>
<table class="table" id="invitations-table"><tbody>
  @foreach ($invitations as $invitation)
    <tr>
      <td>{{ $invitation->email }} · {{ $invitation->role }}</td>
      <td>@if ($invitation->accepted_at) accepted @elseif ($invitation->revoked_at) revoked @else pending @endif</td>
      <td>@if ($invitation->isPending())
        <form method="post" action="/orgs/{{ $organization->slug }}/invitations/{{ $invitation->id }}/revoke" class="inline">@csrf<button class="danger">Revoke</button></form>
      @endif</td>
    </tr>
  @endforeach
</tbody></table>
@endif
@endsection
