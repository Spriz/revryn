<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Personalehuset</title>
  <style>
    :root { --ink:#26323c; --muted:#64748b; --line:#dbe2e8; --accent:#7c3aed; --bg:#f7f7fa; }
    * { box-sizing: border-box; }
    body { margin:0; font:15px/1.5 system-ui,sans-serif; color:var(--ink); background:var(--bg); }
    main { max-width:1080px; margin:0 auto; padding:1.5rem 1rem 4rem; }
    .topbar { display:flex; justify-content:space-between; align-items:center; padding:.6rem 1rem; background:#fff; border-bottom:1px solid var(--line); }
    .topbar nav { display:flex; gap:1rem; align-items:center; }
    .brand { font-weight:700; color:var(--ink); text-decoration:none; }
    a { color:var(--accent); }
    h1 { font-size:1.5rem; } h2 { font-size:1.05rem; margin-top:1.4rem; }
    .card { background:#fff; border:1px solid var(--line); border-radius:10px; padding:1rem; margin:.75rem 0; }
    .card.narrow { max-width:26rem; }
    .card label { display:block; margin:.5rem 0; }
    input,select,textarea { font:inherit; padding:.4rem .5rem; border:1px solid var(--line); border-radius:6px; }
    button { font:inherit; padding:.45rem .9rem; border:0; border-radius:6px; background:var(--accent); color:#fff; cursor:pointer; }
    button.danger { background:#b91c1c; } .linklike { background:none; color:var(--accent); padding:0; border:0; cursor:pointer; }
    .inline { display:inline; } .inlineform { display:flex; gap:.5rem; flex-wrap:wrap; align-items:center; }
    .muted { color:var(--muted); font-size:.85em; }
    .flash { max-width:1080px; margin:.5rem auto; padding:.5rem .9rem; background:#f5f3ff; border:1px solid #c4b5fd; border-radius:8px; overflow-wrap:anywhere; }
    .flash.error { background:#fef2f2; border-color:#f87171; }
    .cardlist { list-style:none; padding:0; } .cardlist li { background:#fff; border:1px solid var(--line); border-radius:8px; padding:.6rem .8rem; margin:.4rem 0; }
    .table { width:100%; border-collapse:collapse; background:#fff; border:1px solid var(--line); }
    .table th,.table td { text-align:left; padding:.5rem .7rem; border-bottom:1px solid var(--line); }
    .subnav { display:flex; gap:1rem; margin:.5rem 0 1rem; flex-wrap:wrap; }
    .grid2 { display:grid; gap:1rem; grid-template-columns:1fr; }
    @media (min-width:800px){ .grid2 { grid-template-columns:1fr 1fr; } }
    .big { font-size:1.2rem; }
    .button { display:inline-block; background:var(--accent); color:#fff; padding:.45rem .9rem; border-radius:6px; text-decoration:none; }
    .done { text-decoration: line-through; color: var(--muted); }
  </style>
</head>
<body>
<header class="topbar">
  <a class="brand" href="/">Personalehuset</a>
  <nav>
    @auth
      <span class="muted">{{ auth()->user()->email }}</span>
      <form method="post" action="/logout" class="inline">@csrf<button class="linklike" id="nav-logout">Sign out</button></form>
    @else
      <a href="/login">Sign in</a> <a href="/register">Register</a>
    @endauth
  </nav>
</header>
@if (session('status'))<div class="flash" id="flash-notice">{{ session('status') }}</div>@endif
@if ($errors->any())<div class="flash error" id="flash-alert">{{ $errors->first() }}</div>@endif
<main>@yield('content')</main>
</body>
</html>
