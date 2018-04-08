-module(dht_server).
-include("dht.hrl").
-behaviour(gen_server).

-export([start_link/2, ping/1]).
-export([init/1, handle_cast/2, handle_info/2, handle_call/3,
         terminate/2, code_change/3]).

%%% Client API
start_link(K, Alpha) ->
    io:format("~p ~p~n", [K, Alpha]),
    io:format("uid: ~p~n", [dht_utils:hash(node())]),
    gen_server:start_link({local, ?MODULE}, ?MODULE, [K, Alpha], []).

ping({_, Other}) ->
    gen_server_call(?MODULE, {request_ping, Other}, 1000);

ping(Other) ->
    Uid = dht_utils:hash(Other),
    ping({Uid, Other}).



gen_server_call(A, B, C) ->
    try
        gen_server:call(A, B, C)
    catch
        exit:{{nodedown, _}, _} ->
            {error, nodedown};
        exit:{timeout, _} ->
            {error, timeout};
        _:x ->  
            {error, timeout}
    end.


%%% Server functions
init([K, Alpha]) -> 
    io:format("~p ~p~n", [K, Alpha]),
    {ok, #state{k=K, alpha=Alpha, uid = dht_utils:hash(node())}}.


handle_call({request_ping, Other}, _, State) ->
    T = gen_server_call({?MODULE, Other}, {ping, {State#state.uid, node()}}, 1000),
    {Out, NewState} = case T of 
              {pong, Target} -> {ok, dht_buckets:update(State, Target)};
              {error, timeout} -> {error, State};
              _ -> {error, State}
    end,
    { reply, Out, NewState };



handle_call({ping, Node}, _From, State) ->
    Routing_table = dht_buckets:update(State, Node),
    io:format('pong!~n'),
    { reply, {pong, {State#state.uid, node()}}, Routing_table }.




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
