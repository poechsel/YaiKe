-module(dht).
-behaviour(application).
-export([start/2, stop/1, ping/0]).
 
start(normal, _Args) ->
    io:format("yes~n"),
    K = get_default(k, 20),
    Alpha = get_default(alpha, 1),
    dht_sup:start_link([K, Alpha]).
 
stop(_State) ->
    ok.


ping() ->
    dht_server:ping().



%% Utility function:

get_default_aux(undefined, D) -> D;
get_default_aux({ok, V}, _) -> V.

get_default(Key, D) ->
    get_default_aux(application:get_env(?MODULE, Key), D).
