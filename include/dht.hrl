-record(state, {k, alpha, uid, store=maps:new()}).
-record(routing, {k, alpha, uid, buckets=array:new(160, {default, []})}).
