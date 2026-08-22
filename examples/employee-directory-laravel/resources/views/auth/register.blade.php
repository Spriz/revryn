@extends('layouts.app')
@section('content')
<h1>Create your account</h1>
<form method="post" action="/register" id="register-form" class="card narrow">@csrf
  <label>Full name <input name="name"></label>
  <label>Email <input type="email" name="email" required></label>
  <label>Password <input type="password" name="password" minlength="8" required></label>
  <button id="register-submit">Create account</button>
  <p><a href="/login">Already registered? Sign in</a></p>
</form>
@endsection
