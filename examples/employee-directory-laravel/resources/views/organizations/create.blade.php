@extends('layouts.app')
@section('content')
<h1>New organization</h1>
<form method="post" action="/orgs" id="create-org-form" class="card narrow">@csrf
  <label>Name <input name="name" required placeholder="e.g. Personalehuset ApS"></label>
  <button id="create-org-submit">Create organization</button>
</form>
@endsection
