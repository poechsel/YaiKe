-module(dht_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    io:format("maybe~n"),
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init(_) ->
    {ok, {{one_for_one, 3, 60},
          [{dht, 
            {dht_server, start_link, []},
            permanent, 1000, worker, [dht_server]}]
         }}.
