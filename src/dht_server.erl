-module(dht_server).
-behaviour(gen_server).

-export([start_link/2, ping/1]).
-export([init/1, handle_cast/2, handle_info/2, handle_call/3,
         terminate/2, code_change/3]).

%%% Client API
start_link(K, Alpha) ->
    io:format("~p ~p~n", [K, Alpha]),
    gen_server:start_link({local, ?MODULE}, ?MODULE, [K, Alpha], []).

ping(Other) ->
    T = gen_server:call({?MODULE, Other}, ping, 1000),
    io:format("-> ~p~n", [T]),
    case T of 
        pong -> ok;
        {error, timeout} -> timeout;
        _ -> io:format("error~n"), timeout
    end.

%%% Server functions
init([K, Alpha]) -> 
    io:format("~p ~p~n", [K, Alpha]),
    {ok, [K, Alpha]}.


handle_call(ping, _From, State) ->
    io:format('pong!~n'),
    { reply, pong, State }.

% temp
handle_cast(ping, State) ->
    io:format('ping!~n'),
    { noreply, State }.

handle_info(Msg, State) ->
    io:format("Unexpected message: ~p~n",[Msg]),
    {noreply, State}.

terminate(normal, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    io:format("code updated~n"),
    %% No change planned. The function is there for the behaviour,
    %% but will not be used. Only a version on the next
    {ok, State}. 
