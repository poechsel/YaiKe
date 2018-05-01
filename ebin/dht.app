{application, dht,
 [{vsn, "1.0.0"},
  {modules, [dht, dht_sup, dht_server]},
  {applications, []},
  {registered, [dht]},
  {mod, {dht, []}},
  {env, [{k, 20}, {alpha, 3}]}
]}.
