@extends('layouts.app')
@section('content')
<h1>Sign in</h1>
<form method="post" action="/login" id="login-form" class="card narrow">@csrf
  <label>Email <input type="email" name="email" required></label>
  <label>Password <input type="password" name="password" required></label>
  <button id="login-submit">Sign in</button>
  <p><a href="/register">New here? Create an account</a></p>
</form>
@endsection
