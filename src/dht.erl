-module(dht).
-behaviour(application).
-export([start/2, stop/1, ping/0]).
 
start(normal, _Args) ->
    io:format("yes~n"),
    dht_sup:start_link().
 
stop(_State) ->
    ok.


ping() ->
    dht_server:ping().
