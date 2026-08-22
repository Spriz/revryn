@extends('layouts.app')
@section('content')
<h1>{{ $organization->name }} · Change history</h1>
<ul class="cardlist" id="changelog-list">
  @foreach ($rows as $row)
    <li><span class="muted">{{ $row->created_at->format('Y-m-d H:i') }}</span>
        <strong>{{ $row->actor?->email }}</strong> {{ $row->summary }}</li>
  @endforeach
</ul>
@endsection
