-module(dht).
-behaviour(application).

-export([start/2, stop/1, ping/1, debug/0, find_nodes/1]).
 
start(normal, _Args) ->
    K = get_default(k, 20),
    Alpha = get_default(alpha, 1),
    dht_sup:start_link([K, Alpha]).
 
stop(_State) ->
    ok.


find_nodes(Target) ->
    dht_server:find_nodes(Target).

ping(Other) ->
    dht_server:ping(Other).

debug() ->
    dht_server:debug().



%% Utility function:

get_default_aux(undefined, D) -> D;
get_default_aux({ok, V}, _) -> V.

get_default(Key, D) ->
    get_default_aux(application:get_env(?MODULE, Key), D).
