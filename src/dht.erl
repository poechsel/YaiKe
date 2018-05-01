-module(dht).
-behaviour(application).

-export([start/2, stop/1, stats/0, store/1, pull/1, broadcast/1, scatter/1, remove/1, connect/1, stop/0]).
start(normal, _Args) ->
    K = get_default(k, 20),
    Alpha = get_default(alpha, 1),
    dht_sup:start_link([K, Alpha]).
 
stop(_State) ->
    ok.


store(Value) ->
    dht_server:store(Value).

pull(Hash) ->
    dht_server:pull(Hash).

broadcast(Msg) ->
    dht_server:broadcast(Msg).

scatter(MsgList) ->
    dht_server:scatter(MsgList).

connect(Node) ->
    dht_server:connect(Node).

remove(Hash) ->
    dht_server:remove(Hash).

stats() ->
    dht_server:stats().

stop() ->
    application:stop(?MODULE).



%% Utility function:

get_default_aux(undefined, D) -> D;
get_default_aux({ok, V}, _) -> V.

get_default(Key, D) ->
    get_default_aux(application:get_env(?MODULE, Key), D).
