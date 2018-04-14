-module(dht_routing_sup).
-behaviour(supervisor).

-export([start_link/1]).
-export([init/1]).

start_link(_Args) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, _Args).

init(_Args) ->
    {ok, {{one_for_one, 3, 60},
          [{dht, 
            {dht_routing, start_link, _Args},
            permanent, 1000, worker, [dht_routing]}]
         }}.
