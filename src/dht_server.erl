-module(dht_server).
-behaviour(gen_server).

-export([start_link/2, ping/0]).
-export([init/1, handle_cast/2, handle_info/2, handle_call/3,
         terminate/2, code_change/3]).

%%% Client API
start_link(K, Alpha) ->
    io:format("~p ~p~n", [K, Alpha]),
    gen_server:start_link(?MODULE, [K, Alpha], []).

ping() ->
    io:format('ping?~n'),
    gen_server:cast(self(), {ping}).

%%% Server functions
init([K, Alpha]) -> 
    io:format("~p ~p~n", [K, Alpha]),
    {ok, [K, Alpha]}.


handle_call({ping}, _From, State) ->
    io:format('pong!~n'),
    { reply, pong, State }.

handle_cast({ping}, State) ->
    io:format('ping!~n'),
    { noreply, State }.

handle_info(Msg, State) ->
    io:format("Unexpected message: ~p~n",[Msg]),
    {noreply, State}.

terminate(normal, State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    %% No change planned. The function is there for the behaviour,
    %% but will not be used. Only a version on the next
    {ok, State}. 
